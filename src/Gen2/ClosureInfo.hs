{-# LANGUAGE QuasiQuotes #-}

module Gen2.ClosureInfo where

import           Data.Bits ((.|.), shiftL)
import           Data.Text (Text)

import           Compiler.JMacro

import           Gen2.StgAst ()

import           StgSyn
import           DataCon
import           TyCon
import           Type
import           Id

-- closure types
data CType = Thunk | Fun | Pap | Con | Blackhole | StackFrame
  deriving (Show, Eq, Ord, Enum, Bounded)

--
ctNum :: CType -> Int
ctNum Fun        = 1
ctNum Con        = 2
ctNum Thunk      = 0 -- 4
ctNum Pap        = 3 -- 8
-- ctNum Ind        = 4 -- 16
ctNum Blackhole  = 5 -- 32
ctNum StackFrame = -1

instance ToJExpr CType where
  toJExpr e = toJExpr (ctNum e)

-- function argument and free variable types
data VarType = PtrV     -- pointer = reference to heap object (closure object)
             | VoidV    -- no fields
--             | FloatV   -- one field -- no single precision supported
             | DoubleV  -- one field
             | IntV     -- one field
             | LongV    -- two fields
             | AddrV    -- a pointer not to the heap: two fields, array + index
             | RtsObjV  -- some RTS object from GHCJS (for example TVar#, MVar#, MutVar#, Weak#)
             | ObjV     -- some JS object, user supplied, be careful around these, can be anything
             | ArrV     -- boxed array
                deriving (Eq, Ord, Show, Enum, Bounded)

-- can we unbox C x to x, only if x is represented as a Number
isUnboxableCon :: DataCon -> Bool
isUnboxableCon dc
  | [t] <- dataConRepArgTys dc, [t1] <- typeVt t =
       isUnboxable t1 &&
       dataConTag dc == 1 &&
       length (tyConDataCons $ dataConTyCon dc) == 1
  | otherwise = False

-- one-constructor types with one primitive field represented as a JS Number
-- can be unboxed
isUnboxable :: VarType -> Bool
isUnboxable DoubleV = True
isUnboxable IntV    = True -- includes Char#
isUnboxable _       = False

varSize :: VarType -> Int
varSize VoidV = 0
varSize LongV = 2 -- hi, low
varSize AddrV = 2 -- obj/array, offset
varSize _     = 1

typeSize :: Type -> Int
typeSize = sum . map varSize . typeVt

isVoid :: VarType -> Bool
isVoid VoidV = True
isVoid _     = False

isPtr :: VarType -> Bool
isPtr PtrV = True
isPtr _    = False

isSingleVar :: VarType -> Bool
isSingleVar v = varSize v == 1

isMultiVar :: VarType -> Bool
isMultiVar v = varSize v > 1

-- can we pattern match on these values in a case?
isMatchable :: [VarType] -> Bool
isMatchable [DoubleV] = True
isMatchable [IntV]    = True
isMatchable _         = False

tyConVt :: TyCon -> [VarType]
tyConVt = typeVt . mkTyConTy

idVt :: Id -> [VarType]
idVt = typeVt . idType

typeVt :: Type -> [VarType]
typeVt t = case repType t of
             UbxTupleRep uts   -> concatMap typeVt uts
             UnaryRep ut       -> [uTypeVt ut]

-- only use if you know it's not an unboxed tuple
uTypeVt :: UnaryType -> VarType
uTypeVt ut
  | isPrimitiveType ut = primTypeVt ut
  | otherwise          = primRepVt . typePrimRep $ ut
  where
    primRepVt VoidRep    = VoidV
    primRepVt PtrRep     = PtrV -- fixme does ByteArray# ever map to this?
    primRepVt IntRep     = IntV
    primRepVt WordRep    = IntV
    primRepVt Int64Rep   = LongV
    primRepVt Word64Rep  = LongV
    primRepVt AddrRep    = AddrV
    primRepVt FloatRep   = DoubleV
    primRepVt DoubleRep  = DoubleV
    primRepVt (VecRep{}) = error "uTypeVt: vector types are unsupported"

primTypeVt :: Type -> VarType
primTypeVt t = case repType t of
                 UnaryRep ut -> case tyConAppTyCon_maybe ut of
                                   Nothing -> error "primTypeVt: not a TyCon"
                                   Just tc -> go (show tc)
                 _ -> error "primTypeVt: non-unary type found"
  where
   pr xs = "ghc-prim:GHC.Prim." ++ xs
   go st
    | st == pr "Addr#"               = AddrV
    | st == pr "Int#"                = IntV
    | st == pr "Int64#"              = LongV
    | st == pr "Char#"               = IntV
    | st == pr "Word#"               = IntV
    | st == pr "Word64#"             = LongV
    | st == pr "Double#"             = DoubleV
    | st == pr "Float#"              = DoubleV
    | st == pr "Array#"              = ArrV
    | st == pr "MutableArray#"       = ArrV
    | st == pr "ByteArray#"          = ObjV -- can contain any JS reference, used for JSRef
    | st == pr "MutableByteArray#"   = ObjV -- can contain any JS reference, used for JSRef
    | st == pr "ArrayArray#"         = ArrV
    | st == pr "MutableArrayArray#"  = ArrV
    | st == pr "MutVar#"             = RtsObjV
    | st == pr "TVar#"               = RtsObjV
    | st == pr "MVar#"               = RtsObjV
    | st == pr "State#"              = VoidV
    | st == pr "RealWorld"           = VoidV
    | st == pr "ThreadId#"           = RtsObjV
    | st == pr "Weak#"               = RtsObjV
    | st == pr "StablePtr#"          = AddrV
    | st == pr "StableName#"         = RtsObjV
    | st == pr "Void#"               = VoidV
    | st == pr "Proxy#"              = VoidV
    | st == pr "MutVar#"             = RtsObjV
    | st == pr "BCO#"                = RtsObjV -- fixme what do we need here?
    | st == pr "~#"                  = VoidV -- coercion token?
    | st == pr "~R#"                 = VoidV -- role
    | st == pr "Any"                 = PtrV
    | st == "Data.Dynamic.Obj"       = PtrV -- ?
    | otherwise = error ("primTypeVt: unrecognized primitive type: " ++ st)

argVt :: StgArg -> VarType
argVt = uTypeVt . stgArgType

instance ToJExpr VarType where
  toJExpr = toJExpr . fromEnum

data ClosureInfo = ClosureInfo
     { ciVar     :: Text      -- ^ object being infod
     , ciRegs    :: CIRegs    -- ^ things in registers when this is the next closure to enter
     , ciName    :: Text      -- ^ friendly name for printing
     , ciLayout  :: CILayout  -- ^ heap/stack layout of the object
     , ciType    :: CIType    -- ^ type of the object, with extra info where required
     , ciStatic  :: CIStatic  -- ^ static references of this object
     }
  deriving (Eq, Ord, Show)

data CIType = CIFun { citArity :: Int  -- ^ function arity
                    , citRegs  :: Int  -- ^ number of registers for the args
                    }
            | CIThunk
            | CICon { citConstructor :: Int }
            | CIPap
            | CIBlackhole
            | CIStackFrame
  --          | CIInd
  deriving (Eq, Ord, Show)

data CIRegs = CIRegsUnknown
            | CIRegs { ciRegsSkip  :: Int       -- ^ unused registers before actual args start
                     , ciRegsTypes :: [VarType] -- ^ args
                     }
  deriving (Eq, Ord, Show)

data CIStatic = -- CIStaticParent { staticParent :: Ident } -- ^ static refs are stored in parent in fungroup
                CIStaticRefs   { staticRefs :: [Text] } -- ^ list of refs that need to be kept alive
  deriving (Eq, Ord, Show)

noStatic :: CIStatic
noStatic = CIStaticRefs []

-- | static refs: array = references, single var = follow parent link, null = nothing to report
instance ToJExpr CIStatic where
--  toJExpr (CIStaticParent p) = iex p -- jsId p
  toJExpr (CIStaticRefs [])  = [je| null |]
  toJExpr (CIStaticRefs rs)  = [je| \ -> `toJExpr rs` |]


data CILayout = CILayoutVariable            -- layout stored in object itself, first position from the start
              | CILayoutUnknown             -- fixed size, but content unknown (for example stack apply frame)
                  { layoutSize :: !Int
                  }
              | CILayoutFixed               -- whole layout known
                  { layoutSize :: !Int      -- closure size in array positions, including entry
                  , layout     :: [VarType]
                  }
  deriving (Eq, Ord, Show)

-- standard fixed layout: payload size
fixedLayout :: [VarType] -> CILayout
fixedLayout vts = CILayoutFixed (sum (map varSize vts)) vts

layoutSizeMaybe :: CILayout -> Maybe Int
layoutSizeMaybe (CILayoutUnknown n) = Just n
layoutSizeMaybe (CILayoutFixed n _) = Just n
layoutSizeMaybe _                   = Nothing

{-
  Some stack frames don't need explicit information, since the
  frame size can be determined from inspecting the types on the stack

  requirements:
    - stack frame
    - fixed size, known layout
    - one register value
    - no ObjV (the next function on the stack should be the start of the next frame, not something in this frame)
    - no static references
 -}
implicitLayout :: ClosureInfo -> Bool
implicitLayout ci
  | CILayoutFixed _ layout <- ciLayout ci
  , CIStaticRefs []        <- ciStatic ci
  , CIStackFrame           <- ciType ci
  , CIRegs 0 rs            <- ciRegs ci =
      sum (map varSize rs) == 1 &&
      null (filter (==ObjV) layout)
  | otherwise = False

instance ToStat ClosureInfo where
  toStat = closureInfoStat False

closureInfoStat :: Bool -> ClosureInfo -> JStat
closureInfoStat debug (ClosureInfo obj rs name layout CIThunk srefs) =
    setObjInfoL debug obj rs layout Thunk name 0 srefs
closureInfoStat debug (ClosureInfo obj rs name layout (CIFun arity nregs) srefs) =
    setObjInfoL debug obj rs layout Fun name (mkArityTag arity nregs) srefs
closureInfoStat debug (ClosureInfo obj rs name layout (CICon con) srefs) =
    setObjInfoL debug obj rs layout Con name con srefs
closureInfoStat debug (ClosureInfo obj rs name layout CIBlackhole srefs)   =
    setObjInfoL debug obj rs layout Blackhole name 0 srefs
closureInfoStat debug (ClosureInfo obj rs name layout CIPap srefs)  =
    setObjInfoL debug obj rs layout Pap name 0 srefs
closureInfoStat debug (ClosureInfo obj rs name layout CIStackFrame srefs) =
    setObjInfoL debug obj rs layout StackFrame name 0 srefs

mkArityTag :: Int -> Int -> Int
mkArityTag arity registers = arity .|. (registers `shiftL` 8)

setObjInfoL :: Bool      -- ^ debug: output symbol names
            -> Text      -- ^ the object name
            -> CIRegs    -- ^ things in registers
            -> CILayout  -- ^ layout of the object
            -> CType     -- ^ closure type
            -> Text      -- ^ object name, for printing
            -> Int       -- ^ `a' argument, depends on type (arity, conid)
            -> CIStatic  -- ^ static refs
            -> JStat
setObjInfoL debug obj rs CILayoutVariable t n a =
  setObjInfo debug obj t n [] a (-1) rs
setObjInfoL debug obj rs (CILayoutUnknown size) t n a =
  setObjInfo debug obj t n xs a size rs
    where
      tag = toJExpr size
      xs  = toTypeList (replicate size ObjV)
setObjInfoL debug obj rs (CILayoutFixed size layout) t n a =
  setObjInfo debug obj t n xs a size rs
    where
      tag  = toJExpr size
      xs   = toTypeList layout

toTypeList :: [VarType] -> [Int]
toTypeList = concatMap (\x -> replicate (varSize x) (fromEnum x))

setObjInfo :: Bool       -- ^ debug: output all symbol names
           -> Text       -- ^ the thing to modify
           -> CType      -- ^ closure type
           -> Text       -- ^ object name, for printing
           -> [Int]      -- ^ list of item types in the object, if known (free variables, datacon fields)
           -> Int        -- ^ extra 'a' parameter, for constructor tag or arity
           -> Int        -- ^ object size, -1 (number of vars) for unknown
           -> CIRegs     -- ^ things in registers [VarType]  -- ^ things in registers
           -> CIStatic   -- ^ static refs
           -> JStat
setObjInfo debug obj t name fields a size regs static
   | debug     = [j| h$setObjInfo(`TxtI obj`, `t`, `name`, `fields`, `a`, `size`, `regTag regs`, `static`); |]
   | otherwise = [j| h$o(`TxtI obj`,`t`,`a`,`size`,`regTag regs`,`static`); |]
  where
    regTag CIRegsUnknown            = -1
    regTag (CIRegs skip types) =
      let nregs = sum $ map varSize types
      in  skip + (nregs `shiftL` 8)
