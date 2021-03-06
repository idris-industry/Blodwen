module Idris.ProcessIdr

import Core.Binary
import Core.Context
import Core.Directory
import Core.UnifyState

import TTImp.ProcessTTImp
import TTImp.Reflect
import TTImp.TTImp

import Idris.Parser
import Idris.Syntax
import Idris.Desugar

import Control.Catchable
import Interfaces.FileIO

processDecl : {auto c : Ref Ctxt Defs} ->
              {auto u : Ref UST (UState FC)} ->
              {auto i : Ref ImpST (ImpState FC)} ->
              {auto s : Ref Syn SyntaxInfo} ->
              PDecl -> Core FC ()
processDecl decl
    = do impdecls <- desugarDecl [] decl 
         traverse (ProcessTTImp.processDecl [] (MkNested [])) impdecls
         pure ()

processDecls : {auto c : Ref Ctxt Defs} ->
               {auto u : Ref UST (UState FC)} ->
               {auto i : Ref ImpST (ImpState FC)} ->
               {auto s : Ref Syn SyntaxInfo} ->
               List PDecl -> Core FC ()
processDecls decls
    = do xs <- traverse processDecl decls
         checkDelayedHoles 
         hs <- getHoleNames
         traverse addToSave hs
         pure ()

readModule : {auto c : Ref Ctxt Defs} ->
             {auto u : Ref UST (UState FC)} ->
             {auto s : Ref Syn SyntaxInfo} ->
             FC ->
             (visible : Bool) -> -- Is import visible to top level module?
             (reexp : Bool) -> -- Should the module be reexported?
             (imp : List String) -> -- Module name to import
             (as : List String) -> -- Namespace to import into
             Core FC ()
readModule loc vis reexp imp as
    = do fname <- nsToPath loc imp
--          coreLift $ putStrLn ("Importing " ++ fname ++ " as " ++ show as ++ 
--                               if reexp then " public" else "")
         Just (syn, more) <- readFromTTC {extra = SyntaxInfo} loc fname imp as
              | Nothing => pure () -- already loaded
         addImported (imp, reexp, as)
         extendAs imp as syn
         modNS <- getNS
         when vis $ setVisible imp
         traverse (\ mimp => 
                       do let m = fst mimp
                          let reexp = fst (snd mimp)
                          let as = snd (snd mimp)
                          readModule loc (vis && reexp) reexp m as) more
         setNS modNS


readImport : {auto c : Ref Ctxt Defs} ->
             {auto u : Ref UST (UState FC)} ->
             {auto s : Ref Syn SyntaxInfo} ->
             Import -> Core FC ()
readImport imp
    = readModule (loc imp) True (reexport imp) (path imp) (nameAs imp)

-- Import a TTC for use as the main file (e.g. at the REPL)
export
readAsMain : {auto c : Ref Ctxt Defs} ->
             {auto u : Ref UST (UState FC)} ->
             {auto s : Ref Syn SyntaxInfo} ->
             (fname : String) -> Core FC ()
readAsMain fname
    = do Just (syn, more) <- readFromTTC {extra = SyntaxInfo} 
                                         toplevelFC fname [] []
              | Nothing => pure ()
         replNS <- getNS
         extendAs replNS replNS syn
         traverse (\ mimp => 
                       do let m = fst mimp
                          let as = snd (snd mimp)
                          fname <- nsToPath emptyFC m
                          readModule emptyFC True False m as) more
         setNS replNS

-- Process everything in the module; return the syntax information which
-- needs to be written to the TTC (e.g. exported infix operators)
processMod : {auto c : Ref Ctxt Defs} ->
             {auto u : Ref UST (UState FC)} ->
             {auto s : Ref Syn SyntaxInfo} ->
             Module -> Core FC ()
processMod mod
    = do i <- newRef ImpST (initImpState {annot = FC})
         let ns = moduleNS mod
         when (ns /= ["Main"]) $
            do let MkFC fname _ _ = headerloc mod
               when (pathToNS fname /= ns) $
                   throw (GenericMsg (headerloc mod) 
                            ("Module name " ++ showSep "." (reverse ns) ++
                             " does not match file name " ++ fname))
         -- read imports here
         -- Note: We should only import .ttc - assumption is that there's
         -- a phase before this which builds the dependency graph
         -- (also that we only build child dependencies if rebuilding
         -- changes the interface - will need to store a hash in .ttc!)
         traverse readImport (imports mod)
         setNS ns
         processDecls (decls mod)

export
process : {auto c : Ref Ctxt Defs} ->
          {auto u : Ref UST (UState FC)} ->
          {auto s : Ref Syn SyntaxInfo} ->
          FileName -> Core FC Bool
process file
    = do Right res <- coreLift (readFile file)
               | Left err => throw (FileErr file err)
         case runParser res (do p <- prog file; eoi; pure p) of
              Left err => throw (ParseFail err)
              Right mod =>
                    catch (do processMod mod
                              makeBuildDirectory (pathToNS file)
                              fn <- getTTCFileName file
                              writeToTTC !(get Syn) fn
                              pure True)
                          (\err => do coreLift (printLn err)
                                      pure False)

