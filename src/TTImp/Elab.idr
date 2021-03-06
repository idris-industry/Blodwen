module TTImp.Elab

import TTImp.TTImp
import public TTImp.Elab.State
import public TTImp.Elab.Term
import Core.CaseTree
import Core.Context
import Core.LinearCheck
import Core.Normalise
import Core.Reflect
import Core.TT
import Core.Unify

import Data.List
import Data.List.Views

%default covering

getRigNeeded : ElabMode -> RigCount
getRigNeeded InType = Rig0 -- unrestricted usage in types
getRigNeeded _ = Rig1

findPLetRenames : Term vars -> List (Name, Name)
findPLetRenames (Bind n (PLet c (Local {x = x@(MN _ _)} p) ty) sc)
    = (x, n) :: findPLetRenames sc
findPLetRenames (Bind n _ sc) = findPLetRenames sc
findPLetRenames tm = []

doPLetRenames : List (Name, Name) -> List Name -> Term vars -> Term vars
doPLetRenames ns drops (Bind n b@(PLet _ _ _) sc)
    = if n `elem` drops
         then subst Erased (doPLetRenames ns drops sc)
         else Bind n b (doPLetRenames ns drops sc)
doPLetRenames ns drops (Bind n b sc)
    = case lookup n ns of
           Just n' => Bind n' b (doPLetRenames ns (n' :: drops) (renameTop n' sc))
           Nothing => Bind n b (doPLetRenames ns drops sc)
doPLetRenames ns drops sc = sc

elabTerm : {auto c : Ref Ctxt Defs} ->
           {auto u : Ref UST (UState annot)} ->
           {auto i : Ref ImpST (ImpState annot)} ->
           Reflect annot =>
           Elaborator annot ->
           Name ->
           Env Term vars -> NestedNames vars ->
           ImplicitMode -> ElabMode ->
           (term : RawImp annot) ->
           (tyin : Maybe (Term vars)) ->
           Core annot (Term vars, Term vars) 
elabTerm process defining env nest impmode elabmode tm tyin
    = do resetHoles
         e <- newRef EST (initEState defining)
         let rigc = getRigNeeded elabmode
         (chktm, ty) <- check {e} rigc process (initElabInfo impmode elabmode) env nest tm tyin
         log 10 $ "Initial check: " ++ show chktm ++ " : " ++ show ty

         -- Final retry of constraints and delayed elaborations
         -- - Solve any constraints, then retry any delayed elaborations
         -- - Finally, one last attempt at solving constraints, but this
         --   is most likely just to be able to display helpful errors
         solveConstraints (case elabmode of
                                InLHS => InLHS
                                _ => InTerm) False
         retryAllDelayed
         -- True flag means "last chance" i.e report error rather than
         -- postponing again (this pass is primarily about error reporting)
         solveConstraints (case elabmode of
                                InLHS => InLHS
                                _ => InTerm) True

         dumpDots
         checkDots
         -- Bind the implicits and any unsolved holes they refer to
         -- This is in implicit mode 'PATTERN' and 'PI'
         fullImps <- getToBind env
         setBound (map fst fullImps) -- maybe not necessary since we're done now
         clearToBind -- remove the bound holes
         gam <- get Ctxt
         log 5 $ "Binding implicits " ++ show fullImps ++
                 " in " ++ show chktm
         est <- get EST
         let (restm, resty) = bindImplicits impmode gam env fullImps 
                                            (asVariables est) chktm ty
         traverse implicitBind (map fst fullImps)
         -- Give implicit bindings their proper names, as UNs not PVs
         gam <- get Ctxt
         let ptm' = renameImplicits (gamma gam) (normaliseHoles gam env restm)
         let pty' = renameImplicits (gamma gam) resty
         log 5 $ "Elaboration result " ++ show ptm'

         normaliseHoleTypes
         clearSolvedHoles
         dumpConstraints 2 False
         case elabmode of
              InLHS => pure ()
              _ => linearCheck (getAnnot tm) rigc env ptm'
         -- If there are remaining holes, we need to save them to the ttc
         -- since they haven't been normalised away yet, and they may be
         -- solved later
         traverse addToSave !getHoleNames
         -- On the LHS, finish by tidying up the plets (changing things that
         -- were of the form x@_, where the _ is inferred to be a variable,
         -- to just x)
         case elabmode of
              InLHS => let vs = findPLetRenames ptm' in
                           do log 5 $ "Renamed PLets " ++ show (doPLetRenames vs [] ptm')
                              pure (doPLetRenames vs [] ptm',
                                    doPLetRenames vs [] pty')
              _ => pure (ptm', pty')

export
inferTerm : {auto c : Ref Ctxt Defs} ->
            {auto u : Ref UST (UState annot)} ->
            {auto i : Ref ImpST (ImpState annot)} ->
            Reflect annot =>
            Elaborator annot -> 
            Name ->
            Env Term vars -> NestedNames vars ->
            ImplicitMode -> ElabMode ->
            (term : RawImp annot) ->
            Core annot (Term vars, Term vars) 
inferTerm process defining env nest impmode elabmode tm 
    = elabTerm process defining env nest impmode elabmode tm Nothing

export
checkTerm : {auto c : Ref Ctxt Defs} ->
            {auto u : Ref UST (UState annot)} ->
            {auto i : Ref ImpST (ImpState annot)} ->
            Reflect annot =>
            Elaborator annot ->
            Name ->
            Env Term vars -> NestedNames vars ->
            ImplicitMode -> ElabMode ->
            (term : RawImp annot) -> (ty : Term vars) ->
            Core annot (Term vars) 
checkTerm process defining env nest impmode elabmode tm ty 
    = do (tm_elab, _) <- elabTerm process defining env nest impmode elabmode tm (Just ty)
         pure tm_elab

