module Inference (typePass, inferKinds) where

import Control.Monad
import Control.Monad.Reader
import Control.Monad.Except (liftEither)
import Control.Monad.Writer
import Control.Monad.State
import Data.List (nub, (\\))
import Data.Foldable (toList)
import qualified Data.Map.Strict as M

import Syntax
import Env
import Record
import Type
import PPrint
import Fresh
import Pass
import Util (onSnd)
import Cat

type Subst   = Env Type
type TempEnv = Env Kind
data InferState = InferState { tempEnv :: TempEnv
                             , subst :: Subst }

type InferM a = Pass TypeEnv InferState a

typePass :: UTopDecl -> TopPass TypeEnv TopDecl
typePass tdecl = case tdecl of
  TopDecl (Let p expr) -> do
    (p', expr') <- liftTop $ inferLetBinding p expr
    putEnv $ foldMap lbind p'
    return $ TopDecl (Let p' expr')
  TopDecl (Unpack b tv expr) -> do
    (ty, expr') <- liftTop (infer expr)
    ty' <- liftEither $ unpackExists ty tv
    let b' = fmap (const ty') b -- TODO: actually check the annotated type
    putEnv $ lbind b' <> tv @> T idxSetKind
    return $ TopDecl (Unpack b' tv expr')
  TopDecl (TAlias _ _) -> error "Shouldn't have TAlias left"
  EvalCmd NoOp -> return (EvalCmd NoOp)
  EvalCmd (Command cmd expr) -> do
    (ty, expr') <- liftTop $ infer expr >>= uncurry generalize
    case cmd of
      GetType -> do writeOutText (pprint ty)
                    return $ EvalCmd NoOp
      Passes  -> do writeOutText ("\nSystem F\n" ++ pprint expr')
                    return $ EvalCmd (Command cmd expr')
      _ -> return $ EvalCmd (Command cmd expr')

liftTop :: HasTypeVars a => InferM a -> TopPass TypeEnv a
liftTop m = do
  source <- getSource
  addErrSource source $ liftTopPass (InferState mempty mempty) mempty (m >>= zonk)

infer :: UExpr -> InferM (Type, Expr)
infer expr = do ty <- freshVar TyKind
                expr' <- check expr ty
                return (ty, expr')

check :: UExpr -> Type -> InferM Expr
check expr reqTy = case expr of
  Lit c -> do
    unifyReq (BaseType (litType c))
    return (Lit c)
  Var v -> do
    maybeTy <- asks $ (flip envLookup v)
    ty <- case maybeTy of Nothing -> throw UnboundVarErr (pprint v)
                          Just (L ty) -> return ty
                          Just (T _ ) -> error "Expected let-bound var"
    instantiate (Var v) ty reqTy (Var v)
  PrimOp b [] args -> do
    let BuiltinType kinds argTys ansTy = builtinType b
    vs <- mapM freshVar kinds
    unifyReq (instantiateTVs vs ansTy)
    let argTys' = map (instantiateTVs vs) argTys
    args' <- zipWithM check args argTys'
    return $ PrimOp b vs args'
  Decls decls body -> foldr checkDecl (check body reqTy) decls
  Lam p body -> do
    (a, b) <- splitFun expr reqTy
    p' <- checkPat p a
    body' <- recurWithP p' body b
    return $ Lam p' body'
  App fexpr arg -> do
    (f, fexpr') <- infer fexpr
    (a, b) <- splitFun expr f
    arg' <- check arg a
    unifyReq b
    return $ App fexpr' arg'
  For p body -> do
    (i, elemTy) <- splitTab expr reqTy
    p' <- checkPat p i
    body' <- recurWithP p' body elemTy
    return $ For p' body'
  Get tabExpr idxExpr -> do
    (tabTy, expr') <- infer tabExpr
    (i, v) <- splitTab expr tabTy
    idxExpr' <- check idxExpr i
    unifyReq v
    return $ Get expr' idxExpr'
  RecCon r -> do
    tyExpr <- traverse infer r
    unifyReq (RecType (fmap fst tyExpr))
    return $ RecCon (fmap snd tyExpr)
  TApp e ts -> do
    -- TODO: can this be made more flexible?
    v <- case stripSrcAnnot e of
           Var v -> return v
           _ -> throw NotImplementedErr
                  "Only variables allowed on LHS of type applications"
    maybeTy <- asks (flip envLookup v)
    ty <- case maybeTy of Nothing -> throw UnboundVarErr (pprint v)
                          Just (L ty) -> return ty
                          Just (T _ ) -> error "Expected let-bound var"
    tyBody <- case ty of Forall _ tyBody -> return tyBody
                         _ -> throw TypeErr "Expected forall type"
    unifyReq (instantiateTVs ts tyBody)
    return $ TApp (Var v) ts
  TabCon _ xs -> do
    (n, elemTy) <- splitTab expr reqTy
    xs' <- mapM (flip check elemTy) xs
    let n' = length xs
    -- `==> elemTy` for better messages
    unifyCtx expr (n ==> elemTy) (IdxSetLit n' ==> elemTy)
    return $ TabCon reqTy xs'
  Pack e ty exTy -> do
    let (Exists exBody) = exTy
    unifyReq exTy
    let t = instantiateTVs [ty] exBody
    e' <- check e t
    return $ Pack e' ty exTy
  DerivAnnot e ann -> do
    e' <- check e reqTy
    ann' <- check ann (tangentBunType reqTy) -- TODO: handle type vars and meta vars)
    return $ DerivAnnot e' ann'
  Annot e annTy -> do
    -- TODO: check that the annotation is a monotype
    unifyReq annTy
    check e reqTy
  SrcAnnot e pos -> addErrSourcePos pos (check e reqTy)
  _ -> error $ "Unexpected expression: " ++ show expr
  where
    unifyReq ty = unifyCtx expr reqTy ty

    checkDecl :: UDecl -> InferM Expr -> InferM Expr
    checkDecl decl cont = case decl of
      Let p bound -> do
        (p', bound') <- inferLetBinding p bound
        extendR (foldMap lbind p') $ do
          body' <- cont
          return $ wrapDecls [Let p' bound'] body'
      Unpack b tv bound -> do
        (maybeEx, bound') <- infer bound >>= zonk
        boundTy <- case maybeEx of Exists t -> return $ instantiateTVs [TypeVar tv] t
                                   _ -> throw TypeErr (pprint maybeEx)
        let b' = replaceAnnot b boundTy
        body' <- extendR (lbind b' <> tv @> T idxSetKind) cont
        tvsEnv <- tempVarsEnv
        tvsReqTy <- tempVars reqTy
        if (tv `elem` tvsEnv) || (tv `elem` tvsReqTy)  then leakErr else return ()
        return $ wrapDecls [Unpack b' tv bound'] body'
      TAlias _ _ -> error "Shouldn't have TAlias left"

    leakErr = throw TypeErr "existential variable leaked"
    recurWithP p e ty = extendR (foldMap lbind p) (check e ty)

inferBinder :: UBinder -> InferM Binder
inferBinder b = liftM (replaceAnnot b) $ case binderAnn b of
                                           NoAnn -> freshTy
                                           Ann ty -> return ty

checkPat :: UPat -> Type -> InferM Pat
checkPat p ty = do (ty', p') <- inferPat p
                   unifyCtx unitCon ty ty'
                   return p'

inferPat :: UPat -> InferM (Type, Pat)
inferPat pat = do tree <- traverse inferBinder pat
                  return (patType tree, tree)

inferLetBinding :: UPat -> UExpr -> InferM (Pat, Expr)
inferLetBinding pat expr = case pat of
  RecLeaf b -> case binderAnn b of
    NoAnn -> do
      (ty', expr') <- infer expr
      (forallTy, tLam) <- generalize ty' expr'
      return (RecLeaf (replaceAnnot b forallTy), tLam)
    Ann sigmaTy@(Forall kinds tyBody) -> do
      skolVars <- mapM (fresh . pprint) kinds
      let skolBinders = zipWith (:>) skolVars kinds
      let exprTy = instantiateTVs (map TypeVar skolVars) tyBody
      expr' <- extendR (foldMap tbind skolBinders) (check expr exprTy)
      return (RecLeaf (replaceAnnot b sigmaTy), TLam skolBinders expr')
    _ -> ansNoGeneralization
  _ -> ansNoGeneralization
  where
    ansNoGeneralization = do
      (patTy, p') <- inferPat pat
      expr' <- check expr patTy
      return (p', expr')

-- TODO: consider expected/actual distinction. App/Lam use it in opposite senses
splitFun :: UExpr -> Type -> InferM (Type, Type)
splitFun e f = case f of
  ArrType a b -> return (a, b)
  _ -> do a <- freshTy
          b <- freshTy
          unifyCtx e f (a --> b)
          return (a, b)

splitTab :: UExpr -> Type -> InferM (IdxSet, Type)
splitTab e t = case t of
  TabType i v -> return (i, v)
  _ -> do i <- freshIdx
          v <- freshTy
          unifyCtx e t (i ==> v)
          return (i, v)

freshVar :: Kind -> InferM Type
freshVar kind = do v <- fresh $ pprint kind
                   modify $ setTempEnv (<> v @> kind)
                   return (TypeVar v)

freshTy :: InferM Type
freshTy  = freshVar TyKind

freshIdx :: InferM Type
freshIdx = freshVar idxSetKind

generalize :: Type -> Expr -> InferM (Type, Expr)
generalize ty expr = do
  ty'   <- zonk ty
  expr' <- zonk expr
  flexVars <- getFlexVars ty' expr'
  case flexVars of
    [] -> return (ty', expr')
    _  -> do kinds <- mapM getKind flexVars
             return (Forall kinds $ abstractTVs flexVars ty',
                     TLam (zipWith (:>) flexVars kinds) expr')
  where
    getKind :: Name -> InferM Kind
    getKind v = gets $ (! v) . tempEnv

getFlexVars :: Type -> Expr -> InferM [Name]
getFlexVars ty expr = do
  tyVars   <- tempVars ty
  exprVars <- tempVars expr
  envVars  <- tempVarsEnv
  return $ nub (tyVars ++ exprVars) \\ envVars

tempVarsEnv :: InferM [Name]
tempVarsEnv = do env <- ask
                 vs <- mapM tempVars [ty | L ty <- toList env]
                 let vs' = [v | (v, T _) <- envPairs env]
                 return $ vs' ++ (concat vs)

tempVars :: HasTypeVars a => a -> InferM [Name]
tempVars x = liftM freeTyVars (zonk x)

instantiate :: UExpr -> Type -> Type -> Expr -> InferM Expr
instantiate e ty reqTy expr = do
  ty'    <- zonk ty
  case ty' of
    Forall kinds body -> do
      vs <- mapM freshVar kinds
      unifyCtx e reqTy (instantiateTVs vs body)
      return $ TApp expr vs
    _ -> do
      unifyCtx e reqTy ty'
      return expr

bindMVar :: Name -> Type -> InferM ()
bindMVar v t | v `occursIn` t = throw TypeErr (pprint (v, t))
             | otherwise = do modify $ setSubst $ (<> v @> t)
                              modify $ setTempEnv $ envDelete v

unifyCtx :: UExpr -> Type -> Type -> InferM ()
unifyCtx expr tyReq tyActual = do
  -- TODO: avoid the double zonking
  tyReq'    <- zonk tyReq
  tyActual' <- zonk tyActual
  let s = "\nExpected: " ++ pprint tyReq'
       ++ "\n  Actual: " ++ pprint tyActual'
       ++ "\nIn: "       ++ pprint expr
  unify s tyReq' tyActual'

-- TODO: check kinds
unify :: String -> Type -> Type -> InferM ()
unify s t1 t2 = do
  t1' <- zonk t1
  t2' <- zonk t2
  env <- ask
  case (t1', t2') of
    _ | t1' == t2'               -> return ()
    (t, TypeVar v) | not (v `isin` env) -> bindMVar v t
    (TypeVar v, t) | not (v `isin` env) -> bindMVar v t
    (ArrType a b, ArrType a' b') -> unify s a a' >> unify s b b'
    (TabType a b, TabType a' b') -> unify s a a' >> unify s b b'
    (Exists t, Exists t')        -> unify s t t'
    (RecType r, RecType r')      ->
      case zipWithRecord (unify s) r r' of
             Nothing -> throw TypeErr s
             Just unifiers -> void $ sequence unifiers
    _ -> throw TypeErr s


occursIn :: Name -> Type -> Bool
occursIn v t = v `elem` freeTyVars t

zonk :: HasTypeVars a => a -> InferM a
zonk x = subFreeTVs lookupVar x

lookupVar :: Name -> InferM Type
lookupVar v = do
  mty <- gets $ flip envLookup v . subst
  case mty of Nothing -> return $ TypeVar v
              Just ty -> do ty' <- zonk ty
                            modify $ setSubst (<> v @> ty')
                            return ty'

setSubst :: (Subst -> Subst) -> InferState -> InferState
setSubst update s = s { subst = update (subst s) }

setTempEnv :: (TempEnv -> TempEnv) -> InferState -> InferState
setTempEnv update s = s { tempEnv = update (tempEnv s) }

inferKinds :: [Name] -> Type -> Except [Kind]
inferKinds vs ty = do
  let kinds = execWriter (collectKinds TyKind ty)
  m <- case fromUnambiguousList kinds of
    Nothing -> throw TypeErr $ "Conflicting kinds for " ++ pprint vs
    Just m -> return m
  let lookupKind v = case M.lookup v m of
        Nothing   -> Left $ Err TypeErr Nothing $ "Ambiguous kind for " ++ pprint v
        Just kind -> Right kind
  mapM lookupKind vs

fromUnambiguousList :: (Ord k, Eq a) => [(k, a)] -> Maybe (M.Map k a)
fromUnambiguousList xs = sequence $ M.fromListWith checkEq (map (onSnd Just) xs)
  where checkEq (Just v) (Just v') | v == v' = Just v
                                   | otherwise = Nothing
        checkEq _ _ = error "Shouldn't happen"

collectKinds :: Kind -> Type -> Writer [(Name, Kind)] ()
collectKinds kind ty = case ty of
  BaseType _    -> return ()
  TypeVar v     -> tell [(v, kind)]
  ArrType a b   -> recur kind       a >> recur kind b
  TabType a b   -> recur idxSetKind a >> recur kind b
  RecType r     -> mapM_ (recur kind) r
  Forall _ body -> recur kind body
  Exists body   -> recur kind body
  IdxSetLit _   -> return ()
  BoundTVar _   -> return ()
  where recur = collectKinds