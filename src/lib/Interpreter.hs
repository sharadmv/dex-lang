{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}

module Interpreter (interpPass) where

import Control.Monad.Reader
import Data.Foldable (fold, toList)
import Data.List (mapAccumL)

import Syntax
import Env
import Pass
import PPrint
import Cat
import Record
import Type
import Fresh

-- TODO: can we make this as dynamic as the compiled version?
foreign import ccall "sqrt" c_sqrt :: Double -> Double
foreign import ccall "sin"  c_sin  :: Double -> Double
foreign import ccall "cos"  c_cos  :: Double -> Double
foreign import ccall "tan"  c_tan  :: Double -> Double
foreign import ccall "exp"  c_exp  :: Double -> Double
foreign import ccall "log"  c_log  :: Double -> Double

type Val = Expr -- irreducible expressions only
type Scope = Env ()
type SubstEnv = (FullEnv Val Type, Scope)
type ReduceM a = Reader SubstEnv a

interpPass :: TopDecl -> TopPass SubstEnv ()
interpPass topDecl = () <$ case topDecl of
  TopDecl decl -> do
    env <- getEnv
    putEnv $ runReader (reduceDecl decl) env
  EvalCmd (Command (EvalExpr Printed) expr) -> do
    env <- getEnv
    writeOutText $ pprint $ runReader (reduce expr) env
  _ -> return ()

reduce :: Expr -> ReduceM Val
reduce expr = case expr of
  Lit _ -> subst expr
  Var _ -> subst expr
  PrimOp Scan _ [x, fs] -> do
    x' <- reduce x
    ~(RecType (Tup [_, ty@(TabType n _)])) <- exprType expr
    fs' <- subst fs
    scope <- asks snd
    let (carry, ys) = mapAccumL (evalScanBody scope fs') x' (enumerateIdxs n)
    return $ RecCon $ Tup [carry, TabCon ty ys]
  PrimOp op ts xs -> do
    ts' <- mapM subst ts
    xs' <- mapM reduce xs
    return $ evalOp op ts' xs'
  Decls [] body -> reduce body
  Decls (decl:rest) body -> do
    env' <- reduceDecl decl
    extendR env' $ reduce (Decls rest body)
  Lam _ _ -> subst expr
  App e1 e2 -> do
    ~(Lam p body) <- reduce e1
    x <- reduce e2
    dropSubst $ extendR (bindPat p x) (reduce body)
  For p body -> do
    ~(ty@(TabType n _)) <- exprType expr
    xs <- flip traverse (enumerateIdxs n) $ \i ->
            extendR (bindPat p i) (reduce body)
    return $ TabCon ty xs
  Get e i -> liftM2 idxTabCon (reduce e) (reduce i)
  RecCon r -> liftM RecCon (traverse reduce r)
  TabCon ty xs -> liftM2 TabCon (subst ty) (mapM reduce xs)
  Pack e ty exTy -> liftM3 Pack (reduce e) (subst ty) (subst exTy)
  IdxLit _ _ -> subst expr
  TLam _ _ -> subst expr
  TApp e1 ts -> do
    ~(TLam bs body) <- reduce e1
    ts' <- mapM subst ts
    let env = asFst $ fold [v @> T t | (v:>_, t) <- zip bs ts']
    dropSubst $ extendR env (reduce body)
  _ -> error $ "Can't evaluate in interpreter: " ++ pprint expr

exprType :: Expr -> ReduceM Type
exprType expr = do expr' <- subst expr
                   return $ getType mempty expr'

evalScanBody :: Scope -> Expr -> Val -> Val -> (Val, Val)
evalScanBody scope (For ip (Lam p body)) accum i =
  case runReader (reduce body) env of
    RecCon (Tup [accum', ys]) -> (accum', ys)
    val -> error $ "unexpected scan result: " ++ pprint val
  where env =  bindPat ip i <> bindPat p accum <> asSnd scope
evalScanBody _ e _ _ = error $ "Bad scan argument: " ++ pprint e

enumerateIdxs :: Type -> [Val]
enumerateIdxs (IdxSetLit n) = map (IdxLit n) [0..n-1]
enumerateIdxs (RecType r) = map RecCon $ traverse enumerateIdxs r  -- list monad
enumerateIdxs ty = error $ "Not an index type: " ++ pprint ty

idxTabCon :: Val -> Val -> Val
idxTabCon (TabCon _ xs) i = xs !! idxToInt i
idxTabCon v _ = error $ "Not a table: " ++ pprint v

idxToInt :: Val -> Int
idxToInt i = snd (flattenIdx i)

intToIdx :: Type -> Int -> Val
intToIdx ty i = idxs !! (i `mod` length idxs)
  where idxs = enumerateIdxs ty

flattenIdx :: Val -> (Int, Int)
flattenIdx (IdxLit n i) = (n, i)
flattenIdx (RecCon r) = foldr f (1,0) $ map flattenIdx (toList r)
  where f (size, idx) (cumSize, cumIdx) = (cumSize * size, cumIdx + idx * cumSize)
flattenIdx v = error $ "Not a valid index: " ++ pprint v

reduceDecl :: Decl -> ReduceM SubstEnv
reduceDecl (Let p expr) = do
  val <- reduce expr
  return $ bindPat p val
reduceDecl (Unpack (v:>_) tv expr) = do
  ~(Pack val ty _) <- reduce expr
  return $ asFst $ v @> L val <> tv @> T ty
reduceDecl (TAlias _ _ ) = error "Shouldn't have TAlias left"

bindPat :: Pat -> Val -> SubstEnv
bindPat (RecLeaf (v:>_)) val = asFst $ v @> L val
bindPat (RecTree r) (RecCon r') = fold $ recZipWith bindPat r r'
bindPat _ _ = error "Bad pattern"

evalOp :: Builtin -> [Type] -> [Val] -> Val
evalOp IAdd _ xs = intBinOp (+) xs
evalOp ISub _ xs = intBinOp (-) xs
evalOp IMul _ xs = intBinOp (*) xs
evalOp Mod  _ xs = intBinOp mod xs
evalOp FAdd _ xs = realBinOp (+) xs
evalOp FSub _ xs = realBinOp (-) xs
evalOp FMul _ xs = realBinOp (*) xs
evalOp FDiv _ xs = realBinOp (/) xs
evalOp BoolToInt _ ~[Lit (BoolLit x)] = Lit $ IntLit (if x then 1 else 0)
evalOp FLT _ ~[x, y] = Lit $ BoolLit $ fromRealLit x < fromRealLit y
evalOp FGT _ ~[x, y] = Lit $ BoolLit $ fromRealLit x > fromRealLit y
evalOp ILT _ ~[x, y] = Lit $ BoolLit $ fromIntLit  x < fromIntLit  y
evalOp IGT _ ~[x, y] = Lit $ BoolLit $ fromIntLit  x > fromIntLit  y
evalOp Range _ ~[x] = Pack unitCon (IdxSetLit (fromIntLit x)) (Exists unitTy)
evalOp IndexAsInt _ ~[x] = Lit (IntLit (idxToInt x))
evalOp IntAsIndex ~[ty] ~[Lit (IntLit x)] = intToIdx ty x
evalOp IntToReal _ ~[Lit (IntLit x)] = Lit (RealLit (fromIntegral x))
evalOp Filter _  ~[f, TabCon (TabType _ ty) xs] =
  exTable ty $ filter (fromBoolLit . asFun f) xs
evalOp (FFICall 1 name) _ xs = case name of
  "sqrt" -> realUnOp c_sqrt xs
  "sin"  -> realUnOp c_sin  xs
  "cos"  -> realUnOp c_cos  xs
  "tan"  -> realUnOp c_tan  xs
  "exp"  -> realUnOp c_exp  xs
  "log"  -> realUnOp c_log  xs
  _ -> error $ "FFI function not recognized: " ++ name
evalOp op _ _ = error $ "Primop not implemented: " ++ pprint op

asFun :: Val -> Val -> Val
asFun f x = runReader (reduce (App f x)) mempty

exTable :: Type -> [Expr] -> Expr
exTable ty xs = Pack (TabCon ty xs) (IdxSetLit (length xs)) exTy
  where exTy = Exists $ TabType (BoundTVar 0) ty

intBinOp :: (Int -> Int -> Int) -> [Val] -> Val
intBinOp op [Lit (IntLit x), Lit (IntLit y)] = Lit $ IntLit $ op x y
intBinOp _ xs = error $ "Bad args: " ++ pprint xs

realBinOp :: (Double -> Double -> Double) -> [Val] -> Val
realBinOp op [Lit (RealLit x), Lit (RealLit y)] = Lit $ RealLit $ op x y
realBinOp _ xs = error $ "Bad args: " ++ pprint xs

realUnOp :: (Double -> Double) -> [Val] -> Val
realUnOp op [Lit (RealLit x)] = Lit $ RealLit $ op x
realUnOp _ xs = error $ "Bad args: " ++ pprint xs

fromIntLit :: Val -> Int
fromIntLit (Lit (IntLit x)) = x
fromIntLit x = error $ "Not an int lit: " ++ pprint x

fromRealLit :: Val -> Double
fromRealLit (Lit (RealLit x)) = x
fromRealLit x = error $ "Not a real lit: " ++ pprint x

fromBoolLit :: Val -> Bool
fromBoolLit (Lit (BoolLit x)) = x
fromBoolLit x = error $ "Not a bool lit: " ++ pprint x

dropSubst :: MonadReader SubstEnv m => m a -> m a
dropSubst m = do local (\(_, scope) -> (mempty, scope)) m

class Subst a where
  subst :: MonadReader SubstEnv m => a -> m a

instance Subst Expr where
  subst expr = case expr of
    Lit _ -> return expr
    Var v -> do
      x <- asks $ flip envLookup v . fst
      case x of
        Nothing -> return expr
        Just (L x') -> dropSubst (subst x')
        Just (T _ ) -> error "Expected let-bound var"
    PrimOp op ts xs -> liftM2 (PrimOp op) (mapM subst ts) (mapM subst xs)
    Decls [] body -> subst body
    Decls (decl:rest) final -> case decl of
      Let p bound -> do
        bound' <- subst bound
        refreshPat p $ \p' -> do
           body' <- subst body
           return $ wrapDecls [Let p' bound'] body'
      Unpack b tv bound -> do
        bound' <- subst bound
        refreshTBinders [tv:>idxSetKind] $ \[tv':>_] ->
          refreshPat [b] $ \[b'] -> do
            body' <- subst body
            return $ wrapDecls [Unpack b' tv' bound'] body'
      TAlias _ _ -> error "Shouldn't have TAlias left"
      where body = Decls rest final
    Lam p body -> do
      refreshPat p $ \p' -> do
        body' <- subst body
        return $ Lam p' body'
    App e1 e2 -> liftM2 App (subst e1) (subst e2)
    For p body -> do
      refreshPat p $ \p' -> do
        body' <- subst body
        return $ For p' body'
    Get e1 e2 -> liftM2 Get (subst e1) (subst e2)
    TLam bs body -> refreshTBinders bs $ \bs' ->
                      liftM (TLam bs') (subst body) -- TODO: freshen binders
    TApp e ts -> liftM2 TApp (subst e) (mapM subst ts)
    RecCon r -> liftM RecCon (traverse subst r)
    IdxLit _ _ -> return expr
    TabCon ty xs -> liftM2 TabCon (subst ty) (mapM subst xs)
    Pack e ty exTy -> liftM3 Pack (subst e) (subst ty) (subst exTy)
    Annot e t -> liftM2 Annot (subst e) (subst t)
    DerivAnnot e1 e2 -> liftM2 DerivAnnot (subst e1) (subst e2)
    SrcAnnot e pos -> liftM (flip SrcAnnot pos) (subst e)

-- Might be able to de-dup these with explicit traversals, lens-style
refreshPat :: (Traversable t, MonadReader SubstEnv m) =>
                t Binder -> (t Binder -> m a) -> m a
refreshPat p m = do
  p' <- traverse (traverse subst) p
  scope <- asks snd
  let (p'', (env', scope')) =
        flip runCat (mempty, scope) $ flip traverse p' $ \(v:>ty) -> do
          v' <- freshCatSubst v
          return (v':>ty)
  extendR (fmap (L . Var) env', scope') $ m p''

refreshTBinders :: MonadReader SubstEnv m => [TBinder] -> ([TBinder] -> m a) -> m a
refreshTBinders bs m = do
  scope <- asks snd
  let (bs', (env', scope')) =
        flip runCat (mempty, scope) $ flip traverse bs $ \(v:>k) -> do
          v' <- freshCatSubst v
          return (v':>k)
  extendR (fmap (T . TypeVar) env', scope') $ m bs'

instance Subst Type where
  subst ty = case ty of
    BaseType _ -> return ty
    TypeVar v -> do
      x <- asks $ flip envLookup v . fst
      return $ case x of Nothing -> ty
                         Just (T ty') -> ty'
                         Just (L _) -> error "Expected type var"
    ArrType a b -> liftM2 ArrType (subst a) (subst b)
    TabType a b -> liftM2 TabType (subst a) (subst b)
    RecType r -> liftM RecType $ traverse subst r
    Forall ks body -> liftM (Forall ks) (subst body)
    Exists body -> liftM Exists (subst body)
    IdxSetLit _ -> return ty
    BoundTVar _ -> return ty