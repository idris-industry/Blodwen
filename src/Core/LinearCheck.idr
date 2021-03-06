module Core.LinearCheck

import Core.Context
import Core.Normalise
import Core.TT
import Core.UnifyState -- just for log level

import Data.List

%default covering

lookup : Elem x vars -> Env Term vars -> (RigCount, Term vars)
lookup Here (b :: bs) = (multiplicity b, weaken (binderType b))
lookup (There p) (b :: bs) 
    = case lookup p bs of
           (c, ty) => (c, weaken ty)

-- List of variable usages - we'll count the contents of specific variables
-- when discharging binders, to ensure that linear names are only used once
data Usage : List Name -> Type where
     Nil : Usage vars
     (::) : Elem x vars -> Usage vars -> Usage vars

Show (Usage vars) where
  show xs = "[" ++ showAll xs ++ "]"
    where
      showAll : Usage vs -> String
      showAll [] = ""
      showAll {vs = v :: _} [el] = show v
      showAll {vs = v :: _} (x :: xs) = show v ++ ", " ++ show xs

Weaken Usage where
  weaken [] = []
  weaken (x :: xs) = There x :: weaken xs

doneScope : Usage (n :: vars) -> Usage vars
doneScope [] = []
doneScope (Here :: xs) = doneScope xs
doneScope (There p :: xs) = p :: doneScope xs

(++) : Usage ns -> Usage ns -> Usage ns
(++) [] ys = ys
(++) (x :: xs) ys = x :: xs ++ ys

count : Elem x ns -> Usage ns -> Nat
count p [] = 0
count p (q :: xs) = if sameVar p q then 1 + count p xs else count p xs

-- If there are holes in the given term, update the hole's type to reflect
-- whether the given variable was used (in a Rig1 position) elsewhere.
-- If it *was* used elsewhere, the hole's type should have it at a rig
-- count of zero, otherwise its rig count should be left alone.
-- That is: the 'useInHole' argument reflects whether the given variable
-- should be treated as Rig1 when we encounter the next hole

-- If there's more than one hole, assume the variable gets used in the
-- first one we encounter (so continue with 'useInHole' as False after
-- encountering a hole)

-- Returns 'False' if no hole encountered (so no need to change usage data
-- for the rest of the definition)
mutual
  updateHoleUsageArgs : {auto c : Ref Ctxt Defs} ->
                        {auto u : Ref UST (UState annot)} ->
                        (useInHole : Bool) ->
                        Elem x vars -> List (Term vars) -> Core annot Bool 
  updateHoleUsageArgs useInHole var [] = pure False
  updateHoleUsageArgs useInHole var (a :: as)
      = do h <- updateHoleUsage useInHole var a
           h' <- updateHoleUsageArgs (useInHole && not h) var as
           pure (h || h')

  updateHoleType : {auto c : Ref Ctxt Defs} ->
                   {auto u : Ref UST (UState annot)} ->
                   (useInHole : Bool) ->
                   Elem x vars -> Nat -> Term vs -> List (Term vars) ->
                   Core annot (Term vs)
  updateHoleType useInHole var (S k) (Bind nm (Pi c e ty) sc) (Local v :: as)
      -- if the argument to the hole type is the variable of interest,
      -- and the variable should be used in the hole, set it to Rig1,
      -- otherwise set it to Rig0
      = if sameVar var v
           then do scty <- updateHoleType False var k sc as
                   let c' = if useInHole then c else Rig0
                   pure (Bind nm (Pi c' e ty) scty)
           else do scty <- updateHoleType useInHole var k sc as
                   pure (Bind nm (Pi c e ty) scty)
  updateHoleType useInHole var (S k) (Bind nm (Pi c e ty) sc) (a :: as)
      = do updateHoleUsage False var a
           scty <- updateHoleType useInHole var k sc as
           pure (Bind nm (Pi c e ty) scty)
  updateHoleType useInHole var _ ty as 
      = do updateHoleUsageArgs False var as
           pure ty

  updateHoleUsage : {auto c : Ref Ctxt Defs} ->
                    {auto u : Ref UST (UState annot)} ->
                    (useInHole : Bool) ->
                    Elem x vars -> Term vars -> Core annot Bool 
  updateHoleUsage useInHole var (Bind n (Let c val ty) sc)
        = do h <- updateHoleUsage useInHole var val
             h' <- updateHoleUsage (useInHole && not h) (There var) sc
             pure (h || h')
  updateHoleUsage useInHole var (Bind n b sc)
        = updateHoleUsage useInHole (There var) sc
  updateHoleUsage useInHole var tm with (unapply tm)
    updateHoleUsage useInHole var (apply (Ref nt fn) args) | ArgsList 
        = do gam <- getCtxt
             case lookupDefTyExact fn gam of
                  Just (Hole locs pvar _, ty)
                    => do ty' <- updateHoleType useInHole var locs ty args
                          log 5 $ "Updated hole type " ++ show fn ++ " : " ++ show ty'
                          updateTy fn ty'
                          pure True
                  _ => updateHoleUsageArgs useInHole var args
    updateHoleUsage useInHole var (apply f []) | ArgsList 
        = pure False
    updateHoleUsage useInHole var (apply f args) | ArgsList 
        = updateHoleUsageArgs useInHole var (f :: args)

-- Linearity checking of an already checked term. This serves two purposes:
--  + Checking correct usage of linear bindings
--  + updating hole types to reflect usage counts correctly
mutual
  lcheck : {auto c : Ref Ctxt Defs} ->
           {auto u : Ref UST (UState annot)} ->
           annot -> RigCount -> Env Term vars -> Term vars -> 
           Core annot (Term vars, Term vars, Usage vars)
  lcheck {vars} loc rig env (Local {x} v) 
      = let (rigb, ty) = lookup v env in
            do rigSafe rigb rig
               pure (Local v, ty, used rig)
    where
      rigSafe : RigCount -> RigCount -> Core annot ()
      rigSafe Rig1 RigW = throw (LinearMisuse loc x Rig1 RigW)
      rigSafe Rig0 RigW = throw (LinearMisuse loc x Rig0 RigW)
      rigSafe Rig0 Rig1 = throw (LinearMisuse loc x Rig0 Rig1)
      rigSafe _ _ = pure ()

      -- count the usage if we're in a linear context. If not, the usage doesn't
      -- matter
      used : RigCount -> Usage vars
      used Rig1 = [v]
      used _ = []

  lcheck loc rig env (Ref nt fn)
      = do gam <- get Ctxt
           case lookupDefTyExact fn (gamma gam) of
                Nothing => throw (InternalError ("Linearity checking failed on " ++ show fn))
                -- Don't count variable usage in holes, so as far as linearity
                -- checking is concerned, update the type so that the binders
                -- are in Rig0
                Just (Hole locs _ _, ty) => 
                     pure (Ref nt fn, embed (unusedHoleArgs locs ty), [])
                Just (def, ty) => pure (Ref nt fn, embed ty, [])
    where
      unusedHoleArgs : Nat -> Term vars -> Term vars
      unusedHoleArgs (S k) (Bind n (Pi _ e ty) sc)
          = Bind n (Pi Rig0 e ty) (unusedHoleArgs k sc)
      unusedHoleArgs _ ty = ty

  lcheck loc rig_in env (Bind nm b sc)
      = do (b', bt, usedb) <- lcheckBinder loc rig env b
           (sc', sct, usedsc) <- lcheck loc rig (b' :: env) sc
           let used = count Here usedsc
           log 10 (show rig ++ " " ++ show nm ++ ": " ++ show used)
           holeFound <- if multiplicity b == Rig1
                           then updateHoleUsage (used == 0) Here sc'
                           else pure False
           -- if there's a hole, assume it will contain the missing usage
           -- if there is none already
           checkUsageOK (if holeFound && used == 0 then 1 else used)
                        (rigMult (multiplicity b) rig)
           pure $ discharge nm b' bt sc' sct (usedb ++ doneScope usedsc)
    where
      rig : RigCount
      rig = case b of
                 Pi _ _ _ => Rig0
                 _ => rig_in

      checkUsageOK : Nat -> RigCount -> Core annot ()
      checkUsageOK used Rig0 = pure ()
      checkUsageOK used RigW = pure ()
      checkUsageOK used Rig1 
          = if used == 1 
               then pure ()
               else throw (LinearUsed loc used nm)

  lcheck loc rig env (App f a)
      = do (f', fty, fused) <- lcheck loc rig env f
           gam <- get Ctxt
           case nf gam env fty of
                NBind _ (Pi rigf _ ty) scdone =>
                   do (a', aty, aused) <- lcheck loc (rigMult rigf rig) env a
                      let sc' = scdone (toClosure False env a')
                      pure (App f' a', quote (noGam gam) env sc', fused ++ aused)
                _ => throw (InternalError ("Linearity checking failed on " ++ show f' ++ 
                              " (" ++ show fty ++ " not a function type)"))

  lcheck loc rig env (PrimVal x) = pure (PrimVal x, Erased, [])
  lcheck loc rig env Erased = pure (Erased, Erased, [])
  lcheck loc rig env TType = pure (TType, TType, [])

  lcheckBinder : {auto c : Ref Ctxt Defs} ->
                 {auto u : Ref UST (UState annot)} ->
                 annot -> RigCount -> Env Term vars -> 
                 Binder (Term vars) -> 
                 Core annot (Binder (Term vars), Term vars, Usage vars)
  lcheckBinder loc rig env (Lam c x ty)
      = do (tyv, tyt, _) <- lcheck loc Rig0 env ty
           pure (Lam c x tyv, tyt, [])
  lcheckBinder loc rig env (Let rigc val ty)
      = do (tyv, tyt, _) <- lcheck loc Rig0 env ty
           (valv, valt, vs) <- lcheck loc (rigMult rig rigc) env val
           pure (Let rigc valv tyv, tyt, vs)
  lcheckBinder loc rig env (Pi c x ty)
      = do (tyv, tyt, _) <- lcheck loc Rig0 env ty
           pure (Pi c x tyv, tyt, [])
  lcheckBinder loc rig env (PVar c ty)
      = do (tyv, tyt, _) <- lcheck loc Rig0 env ty
           pure (PVar c tyv, tyt, [])
  lcheckBinder loc rig env (PLet rigc val ty)
      = do (tyv, tyt, _) <- lcheck loc Rig0 env ty
           (valv, valt, vs) <- lcheck loc (rigMult rig rigc) env val
           pure (PLet rigc valv tyv, tyt, vs)
  lcheckBinder loc rig env (PVTy c ty)
      = do (tyv, tyt, _) <- lcheck loc Rig0 env ty
           pure (PVTy c tyv, tyt, [])
  
  discharge : (nm : Name) -> Binder (Term vars) -> Term vars ->
              Term (nm :: vars) -> Term (nm :: vars) -> Usage vars ->
              (Term vars, Term vars, Usage vars)
  discharge nm (Lam c x ty) bindty scope scopety used
       = (Bind nm (Lam c x ty) scope, Bind nm (Pi c x ty) scopety, used)
  discharge nm (Let c val ty) bindty scope scopety used
       = (Bind nm (Let c val ty) scope, Bind nm (Let c val ty) scopety, used)
  discharge nm (Pi c x ty) bindty scope scopety used
       = (Bind nm (Pi c x ty) scope, bindty, used)
  discharge nm (PVar c ty) bindty scope scopety used
       = (Bind nm (PVar c ty) scope, Bind nm (PVTy c ty) scopety, used)
  discharge nm (PLet c val ty) bindty scope scopety used
       = (Bind nm (PLet c val ty) scope, Bind nm (PLet c val ty) scopety, used)
  discharge nm (PVTy c ty) bindty scope scopety used
       = (Bind nm (PVTy c ty) scope, bindty, used)

bindEnv : Env Term vars -> (tm : Term vars) -> ClosedTerm
bindEnv [] tm = tm
bindEnv (b :: env) tm 
    = bindEnv env (Bind _ b tm)

export
linearCheck : {auto c : Ref Ctxt Defs} ->
              {auto u : Ref UST (UState annot)} ->
              annot -> RigCount -> Env Term vars -> Term vars -> 
              Core annot ()
linearCheck loc rig env tm
    = do log 5 $ "Linearity check on " ++ show (bindEnv env tm)
         lcheck loc rig [] (bindEnv env tm)
         pure ()

