{-# LANGUAGE TupleSections #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
module Futhark.DistributeKernels.Distribution
       (
         Target
       , Targets
       , ppTargets
       , singleTarget
       , innerTarget
       , outerTarget
       , pushOuterTarget
       , pushInnerTarget

       , LoopNesting (..)

       , Nesting (..)
       , Nestings
       , ppNestings
       , letBindInInnerNesting
       , singleNesting
       , pushInnerNesting

       , KernelNest
       , constructKernel

       , tryDistribute
       , tryDistributeBinding

       , SeqLoop (..)
       , interchangeLoops
       )
       where

import Control.Applicative
import Control.Monad.RWS.Strict
import Control.Monad.Trans.Maybe
import qualified Data.HashMap.Lazy as HM
import qualified Data.HashSet as HS
import Data.Maybe
import Data.List
import Debug.Trace

import Futhark.Representation.Basic
import Futhark.MonadFreshNames
import Futhark.Tools
import Futhark.Util
import Futhark.Renamer

import Prelude

type Target = (Pattern, Result)

-- ^ First pair element is the very innermost ("current") target.  In
-- the list, the outermost target comes first.
type Targets = (Target, [Target])

ppTargets :: Targets -> String
ppTargets (target, targets) =
  unlines $ map ppTarget $ targets ++ [target]
  where ppTarget (pat, res) =
          pretty pat ++ " <- " ++ pretty res

singleTarget :: Target -> Targets
singleTarget = (,[])

innerTarget :: Targets -> Target
innerTarget = fst

outerTarget :: Targets -> Target
outerTarget (inner_target, []) = inner_target
outerTarget (_, outer_target : _) = outer_target

pushOuterTarget :: Target -> Targets -> Targets
pushOuterTarget target (inner_target, targets) =
  (inner_target, target : targets)

pushInnerTarget :: Target -> Targets -> Targets
pushInnerTarget target (inner_target, targets) =
  (target, targets ++ [inner_target])

data LoopNesting = MapNesting Pattern Certificates SubExp [(LParam, VName)]
                 deriving (Show)

loopNestingPattern :: LoopNesting -> Pattern
loopNestingPattern (MapNesting pat _ _ _) =
  pat

loopNestingParams :: LoopNesting -> [LParam]
loopNestingParams (MapNesting _ _ _ params_and_arrs) =
  map fst params_and_arrs

instance FreeIn LoopNesting where
  freeIn (MapNesting pat cs w params_and_arrs) =
    freeInPattern pat <>
    freeIn cs <>
    freeIn w <>
    freeIn params_and_arrs

data Nesting = Nesting { nestingLetBound :: Names
                       , nestingLoop :: LoopNesting
                       }
             deriving (Show)

letBindInNesting :: Names -> Nesting -> Nesting
letBindInNesting newnames (Nesting oldnames loop) =
  Nesting (oldnames <> newnames) loop

-- ^ First pair element is the very innermost ("current") nest.  In
-- the list, the outermost nest comes first.
type Nestings = (Nesting, [Nesting])

ppNestings :: Nestings -> String
ppNestings (nesting, nestings) =
  unlines $ map ppNesting $ nestings ++ [nesting]
  where ppNesting (Nesting _ (MapNesting _ _ _ params_and_arrs)) =
          pretty (map fst params_and_arrs) ++
          " <- " ++
          pretty (map snd params_and_arrs)

singleNesting :: Nesting -> Nestings
singleNesting = (,[])

pushInnerNesting :: Nesting -> Nestings -> Nestings
pushInnerNesting nesting (inner_nesting, nestings) =
  (nesting, nestings ++ [inner_nesting])

-- | Both parameters and let-bound.
boundInNesting :: Nesting -> Names
boundInNesting nesting =
  HS.fromList (map paramName (loopNestingParams $ nestingLoop nesting)) <>
  nestingLetBound nesting

letBindInInnerNesting :: Names -> Nestings -> Nestings
letBindInInnerNesting names (nest, nestings) =
  (letBindInNesting names nest, nestings)


-- | Note: first element is *outermost* nesting.  This is different
-- from the similar types elsewhere!
type KernelNest = (LoopNesting, [LoopNesting])

-- | Add new outermost nesting, pushing the current outermost to the
-- list.
pushKernelNesting :: LoopNesting -> KernelNest -> KernelNest
pushKernelNesting newnest (nest, nests) =
  (newnest, nest : nests)

newKernel :: LoopNesting -> KernelNest
newKernel nest = (nest, [])

kernelNestLoops :: KernelNest -> [LoopNesting]
kernelNestLoops (loop, loops) = loop : loops

constructKernel :: KernelNest -> Body -> Binding
constructKernel (MapNesting pat cs w params_and_arrs, []) body =
  Let pat () $ LoopOp $
  Map cs w (Lambda params body rettype) arrs
  where (params, arrs) = unzip params_and_arrs
        rettype = map rowType $ patternTypes pat
constructKernel (MapNesting pat cs w params_and_arrs, nest : nests) inner_body =
  Let pat () $ LoopOp $
  Map cs w (Lambda params body rettype) arrs
  where (params, arrs) = unzip params_and_arrs
        rettype = map rowType $ patternTypes pat
        bnd = constructKernel (nest, nests) inner_body
        body = mkBody [bnd] $ map Var $ patternNames $ bindingPattern bnd

-- | Description of distribution to do.
data DistributionBody = DistributionBody {
    distributionTarget :: Targets
  , distributionFreeInBody :: Names
  , distributionIdentityMap :: HM.HashMap VName Ident
  , distributionExpandTarget :: Target -> Target
    -- ^ Also related to avoiding identity mapping.
  }

distributionInnerPattern :: DistributionBody -> Pattern
distributionInnerPattern = fst . innerTarget . distributionTarget

distributionBodyFromBindings :: Targets -> [Binding] -> (DistributionBody, Result)
distributionBodyFromBindings ((inner_pat, inner_res), targets) bnds =
  let bound_by_bnds = boundByBindings bnds
      (inner_pat', inner_res', inner_identity_map, inner_expand_target) =
        removeIdentityMappingGeneral bound_by_bnds inner_pat inner_res
  in (DistributionBody
      { distributionTarget = ((inner_pat', inner_res'), targets)
      , distributionFreeInBody = mconcat (map freeInBinding bnds)
                                 `HS.difference` bound_by_bnds
      , distributionIdentityMap = inner_identity_map
      , distributionExpandTarget = inner_expand_target
      },
      inner_res')

distributionBodyFromBinding :: Targets -> Binding -> (DistributionBody, Result)
distributionBodyFromBinding targets bnd =
  distributionBodyFromBindings targets [bnd]

createKernelNest :: (MonadFreshNames m, HasTypeEnv m) =>
                    Nestings
                 -> DistributionBody
                 -> m (Maybe (Targets, KernelNest))
createKernelNest (inner_nest, nests) distrib_body = do
  let (target, targets) = distributionTarget distrib_body
  unless (length nests == length targets) $
    fail $ "Nests and targets do not match!\n" ++
    "nests: " ++ ppNestings (inner_nest, nests) ++
    "\ntargets:" ++ ppTargets (target, targets)
  runMaybeT $ liftM prepare $ recurse $ zip nests targets

  where prepare (x, _, z) = (z, x)
        bound_in_nest =
          mconcat $ map boundInNesting $ inner_nest : nests
        liftedTypeOK =
          HS.null . HS.intersection bound_in_nest . freeIn . arrayDims

        distributeAtNesting :: (HasTypeEnv m, MonadFreshNames m) =>
                               Nesting
                            -> Pattern
                            -> (LoopNesting -> KernelNest, Names)
                            -> HM.HashMap VName Ident
                            -> [Ident]
                            -> (Target -> Targets)
                            -> MaybeT m (KernelNest, Names, Targets)
        distributeAtNesting
          (Nesting nest_let_bound nest)
          pat
          (add_to_kernel, free_in_kernel)
          identity_map
          inner_returned_arrs
          addTarget = do
          let nest'@(MapNesting _ cs w params_and_arrs) =
                removeUnusedNestingParts nest free_in_kernel
              (params,arrs) = unzip params_and_arrs
              param_names = HS.fromList $ map paramName params
              free_in_kernel' =
                (freeIn nest' <> free_in_kernel) `HS.difference` param_names
              required_from_nest =
                free_in_kernel' `HS.intersection` nest_let_bound

          required_from_nest_idents <-
            forM (HS.toList required_from_nest) $ \name -> do
              t <- lift $ lookupType name
              return $ Ident name t

          (free_params, free_arrs, bind_in_target) <-
            liftM unzip3 $
            forM (inner_returned_arrs++required_from_nest_idents) $
            \(Ident pname ptype) -> do
              unless (liftedTypeOK ptype) $
                fail "Would induce irregular array"
              case HM.lookup pname identity_map of
                Nothing -> do
                  arr <- newIdent (baseString pname ++ "_r") $
                         arrayOfRow ptype w
                  return (Param (Ident pname ptype) (),
                          arr,
                          True)
                Just arr ->
                  return (Param (Ident pname ptype) (),
                          arr,
                          False)

          let free_arrs_pat =
                basicPattern [] $ map ((,BindVar) . snd) $
                filter fst $ zip bind_in_target free_arrs
              free_params_pat =
                map snd $ filter fst $ zip bind_in_target free_params

              nest'' =
                removeUnusedNestingParts
                (MapNesting pat cs w $ zip actual_params actual_arrs)
                free_in_kernel
              actual_param_names =
                HS.fromList $ map paramName actual_params

              free_in_kernel'' =
                (freeIn nest'' <> free_in_kernel) `HS.difference` actual_param_names

              (actual_params, actual_arrs) =
                (params++free_params,
                 arrs++map identName free_arrs)

          return (add_to_kernel nest'',

                  free_in_kernel'',

                  addTarget (free_arrs_pat, map (Var . paramName) free_params_pat))

        recurse :: (HasTypeEnv m, MonadFreshNames m) =>
                   [(Nesting,Target)]
                -> MaybeT m (KernelNest, Names, Targets)
        recurse [] =
          distributeAtNesting
          inner_nest
          (distributionInnerPattern distrib_body)
          (newKernel,
           distributionFreeInBody distrib_body `HS.intersection` bound_in_nest)
          (distributionIdentityMap distrib_body)
          [] $
          singleTarget . distributionExpandTarget distrib_body

        recurse ((nest, (pat,res)) : nests') = do
          (kernel@(outer, _), kernel_names, kernel_targets) <- recurse nests'

          let (pat', identity_map, expand_target) =
                removeIdentityMappingFromNesting
                (HS.fromList $ patternNames $ loopNestingPattern outer) pat res

          distributeAtNesting
            nest
            pat'
            ((`pushKernelNesting` kernel),
             kernel_names)
            identity_map
            (patternIdents $ fst $ outerTarget kernel_targets)
            ((`pushOuterTarget` kernel_targets) . expand_target)

removeUnusedNestingParts :: LoopNesting -> Names -> LoopNesting
removeUnusedNestingParts (MapNesting pat cs w params_and_arrs) used =
  MapNesting pat cs w $ zip used_params used_arrs
  where (params,arrs) = unzip params_and_arrs
        (used_params, used_arrs) =
          unzip $
          filter ((`HS.member` used) . paramName . fst) $
          zip params arrs

removeIdentityMappingGeneral :: Names -> Pattern -> Result
                             -> (Pattern,
                                 Result,
                                 HM.HashMap VName Ident,
                                 Target -> Target)
removeIdentityMappingGeneral bound pat res =
  let (identities, not_identities) =
        mapEither isIdentity $ zip (patternElements pat) res
      (not_identity_patElems, not_identity_res) = unzip not_identities
      (identity_patElems, identity_res) = unzip identities
      expandTarget (tpat, tres) =
        (Pattern [] $ patternElements tpat ++ identity_patElems,
         tres ++ map Var identity_res)
      identity_map = HM.fromList $ zip identity_res $
                      map patElemIdent identity_patElems
  in (Pattern [] not_identity_patElems,
      not_identity_res,
      identity_map,
      expandTarget)
  where isIdentity (patElem, Var v)
          | not (v `HS.member` bound) = Left (patElem, v)
        isIdentity x                  = Right x

removeIdentityMappingFromNesting :: Names -> Pattern -> Result
                                 -> (Pattern,
                                     HM.HashMap VName Ident,
                                     Target -> Target)
removeIdentityMappingFromNesting bound_in_nesting pat res =
  let (pat', _, identity_map, expand_target) =
        removeIdentityMappingGeneral bound_in_nesting pat res
  in (pat', identity_map, expand_target)

tryDistribute :: (MonadFreshNames m, HasTypeEnv m) =>
                 Nestings -> Targets -> [Binding]
              -> m (Maybe (Targets, [Binding]))
tryDistribute _ targets [] =
  -- No point in distributing an empty kernel.
  return $ Just (targets, [])
tryDistribute nest targets bnds =
  createKernelNest nest dist_body >>=
  \case
    Just (targets', distributed) -> do
      distributed' <- optimiseKernel <$>
                      renameBinding (constructKernel distributed inner_body)
      trace ("distributing\n" ++
             pretty (mkBody bnds $ snd $ innerTarget targets) ++
             "\nas\n" ++ pretty distributed' ++
             "\ndue to targets\n" ++ ppTargets targets ++
             "\nand with new targets\n" ++ ppTargets targets') return $
        Just (targets', [distributed'])
    Nothing ->
      return Nothing
  where (dist_body, inner_body_res) = distributionBodyFromBindings targets bnds
        inner_body = mkBody bnds inner_body_res

tryDistributeBinding :: (MonadFreshNames m, HasTypeEnv m) =>
                        Nestings -> Targets -> Binding
                     -> m (Maybe (Result, Targets, KernelNest))
tryDistributeBinding nest targets bnd =
  liftM addRes <$> createKernelNest nest dist_body
  where (dist_body, res) = distributionBodyFromBinding targets bnd
        addRes (targets', kernel_nest) = (res, targets', kernel_nest)

data SeqLoop = SeqLoop Pattern [VName] [(FParam, SubExp)] LoopForm Body

seqLoopBinding :: SeqLoop -> Binding
seqLoopBinding (SeqLoop pat ret merge form body) =
  Let pat () $ LoopOp $ DoLoop ret merge form body

interchangeLoop :: MonadBinder m =>
                   SeqLoop -> LoopNesting
                -> m SeqLoop
interchangeLoop
  (SeqLoop loop_pat ret merge form body)
  (MapNesting pat cs w params_and_arrs) = do
    merge_expanded <- mapM expand merge

    let ret_params_mask = map ((`elem` ret) . paramName . fst) merge
        ret_expanded = [ paramName param
                       | ((param,_), used) <- zip merge_expanded ret_params_mask,
                         used]
        loop_pat_expanded =
          Pattern [] $ map expandPatElem $ patternElements loop_pat
        new_params = map fst merge
        new_arrs = map (paramName . fst) merge_expanded
        rettype = map rowType $ patternTypes loop_pat_expanded

    -- If the map consumes something that is bound outside the loop
    -- (i.e. is not a merge parameter), we have to copy() it.  As a
    -- small simplification, we just remove the parameter outright if
    -- it is not used anymore.  This might happen if the parameter was
    -- used just as the inital value of a merge parameter.
    ((params', arrs'), copy_bnds) <-
      runBinder $ bindingParamTypes new_params $
      unzip <$> catMaybes <$> mapM copyOrRemoveParam params_and_arrs

    let lam = Lambda (params'<>new_params) body rettype
        map_bnd = Let loop_pat_expanded () $
                  LoopOp $ Map cs w lam $ arrs' <> new_arrs
        res = map Var $ patternNames loop_pat_expanded

    return $
      SeqLoop pat ret_expanded merge_expanded form $
      mkBody (copy_bnds++[map_bnd]) res
  where free_in_body = freeInBody body

        copyOrRemoveParam (param, arr)
          | not (paramName param `HS.member` free_in_body) =
            return Nothing
          | unique $ paramType param = do
              arr' <- newVName $ baseString arr <> "_copy"
              let arr_t = arrayOfRow (paramType param) w
              addBinding $
                Let (basicPattern' [] [Ident arr' arr_t]) () $
                PrimOp $ Copy arr
              return $ Just (param, arr')
          | otherwise =
            return $ Just (param, arr)

        expandedInit _ (Var v)
          | Just arr <- snd <$> find ((==v).paramName.fst) params_and_arrs =
              return $ Var arr
        expandedInit param_name se =
          letSubExp (param_name <> "_expanded_init") $
            PrimOp $ Replicate w se

        expand (merge_param, merge_init) = do
          expanded_param <-
            newIdent (param_name <> "_expanded") $
            arrayOfRow (paramType merge_param) w
          expanded_init <- expandedInit param_name merge_init
          return (Param expanded_param (), expanded_init)
            where param_name = baseString $ paramName merge_param

        expandPatElem patElem =
          patElem { patElemIdent = expandIdent $ patElemIdent patElem }

        expandIdent ident =
          ident { identType = arrayOfRow (identType ident) w }

interchangeLoops :: (MonadFreshNames m, HasTypeEnv m) =>
                    KernelNest -> SeqLoop
                 -> m [Binding]

interchangeLoops nest loop = do
  (loop', bnds) <-
    runBinder $ foldM interchangeLoop loop $ reverse $ kernelNestLoops nest
  return $ bnds ++ [seqLoopBinding loop']

optimiseKernel :: Binding -> Binding
optimiseKernel bnd = fromMaybe bnd $ tryOptimiseKernel bnd

tryOptimiseKernel :: Binding -> Maybe Binding
tryOptimiseKernel bnd = kernelIsRearrange bnd <|>
                        kernelIsReshape bnd <|>
                        kernelBodyOptimisable bnd

singleBindingBody :: Body -> Maybe Binding
singleBindingBody (Body _ [bnd] [res])
  | [res] == map Var (patternNames $ bindingPattern bnd) =
      Just bnd
singleBindingBody _ = Nothing

singleExpBody :: Body -> Maybe Exp
singleExpBody = liftM bindingExp . singleBindingBody

kernelIsRearrange :: Binding -> Maybe Binding
kernelIsRearrange (Let outer_pat _
                   (LoopOp (Map outer_cs _ outer_fun [outer_arr]))) =
  delve 1 outer_cs outer_fun
  where delve n cs (Lambda [param] body _)
          | Just (PrimOp (Rearrange inner_cs perm arr)) <-
              singleExpBody body,
            paramName param == arr =
              let cs' = cs ++ inner_cs
                  perm' = [0..n-1] ++ map (n+) perm
              in Just $ Let outer_pat () $
                 PrimOp $ Rearrange cs' perm' outer_arr
          | Just (LoopOp (Map inner_cs _ fun [arr])) <- singleExpBody body,
            paramName param == arr =
            delve (n+1) (cs++inner_cs) fun
        delve _ _ _ =
          Nothing
kernelIsRearrange _ = Nothing

kernelIsReshape :: Binding -> Maybe Binding
kernelIsReshape (Let (Pattern [] [outer_patElem]) ()
                 (LoopOp (Map outer_cs _ outer_fun [outer_arr]))) =
  delve outer_cs outer_fun
    where new_shape = arrayDims $ patElemType outer_patElem

          delve cs (Lambda [param] body _)
            | Just (PrimOp (Reshape inner_cs _ arr)) <-
              singleExpBody body,
              paramName param == arr =
              let cs' = cs ++ inner_cs
              in Just $ Let (Pattern [] [outer_patElem]) () $
                 PrimOp $ Reshape cs' new_shape outer_arr

            | Just (LoopOp (Map inner_cs _ fun [arr])) <- singleExpBody body,
              paramName param == arr =
              delve (cs++inner_cs) fun

          delve _ _ =
            Nothing
kernelIsReshape _ = Nothing

kernelBodyOptimisable :: Binding -> Maybe Binding
kernelBodyOptimisable (Let pat () (LoopOp (Map cs w fun arrs))) = do
  bnd <- tryOptimiseKernel =<< singleBindingBody (lambdaBody fun)
  let body = (lambdaBody fun) { bodyBindings = [bnd] }
  return $ Let pat () $ LoopOp $ Map cs w fun { lambdaBody = body } arrs
kernelBodyOptimisable _ =
  Nothing