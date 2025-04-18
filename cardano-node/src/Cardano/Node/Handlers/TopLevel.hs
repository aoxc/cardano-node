{-# LANGUAGE TypeApplications #-}

module Cardano.Node.Handlers.TopLevel
  ( toplevelExceptionHandler
  ) where

-- The code in this module derives from multiple authors over many years.
-- It is all under the BSD3 license below.
--
-- Copyright (c) 2019 Input Output Global Inc (IOG).
--               2017 Edward Z. Yang
--               2015 Edsko de Vries
--               2009 Duncan Coutts
--               2007 Galois Inc.
--               2003 Isaac Jones, Simon Marlow
--
-- Copyright (c) 2003-2017, Cabal Development Team.
-- See the AUTHORS file for the full list of copyright holders.
-- All rights reserved.
--
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions are
-- met:
--
--     * Redistributions of source code must retain the above copyright
--       notice, this list of conditions and the following disclaimer.
--
--     * Redistributions in binary form must reproduce the above
--       copyright notice, this list of conditions and the following
--       disclaimer in the documentation and/or other materials provided
--       with the distribution.
--
--     * Neither the name of Isaac Jones nor the names of other
--       contributors may be used to endorse or promote products derived
--       from this software without specific prior written permission.
--
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
-- "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
-- LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
-- A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
-- OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
-- SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
-- LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
-- DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
-- THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
-- (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
-- OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import qualified Ouroboros.Network.Diffusion.Common as Network

import           Prelude

import           Control.Exception
import           Control.Monad.Class.MonadAsync (ExceptionInLinkedThread (..))
import           System.Environment
import           System.Exit
import           System.IO

-- | An exception handler to use for a program top level, as an alternative to
-- the default top level handler provided by GHC.
--
-- Use like:
--
-- > main :: IO ()
-- > main = toplevelExceptionHandler $ do
-- >   ...
--
toplevelExceptionHandler :: IO a -> IO a
toplevelExceptionHandler prog = do
    -- Use line buffering in case we have to print big error messages, because
    -- by default stderr to a terminal device is NoBuffering which is slow.
    hSetBuffering stderr LineBuffering
    catches prog [
        Handler rethrowAsyncExceptions
      , Handler rethrowExitCode
      , Handler handleDiffusionError
      , Handler handleSomeException
      ]
  where
    -- Let async exceptions rise to the top for the default GHC top-handler.
    -- This includes things like CTRL-C. If a linked thread throws ExitSuccess,
    -- then we rethrow ExitSuccess. This happens for example when using the
    -- `--shutdown-on-slot-synced` option.
    rethrowAsyncExceptions :: SomeAsyncException -> IO a
    rethrowAsyncExceptions full@(SomeAsyncException e) =
      case fromException (toException e) of
        Just (ExceptionInLinkedThread _ eInner)
          | Just ExitSuccess <- fromException eInner
          -> throwIO ExitSuccess
        _ -> throwIO full

    -- We don't want to print ExitCode, and it should be handled by the default
    -- top handler because that sets the actual OS process exit code.
    rethrowExitCode :: ExitCode -> IO a
    rethrowExitCode = throwIO

    -- Handle errors thrown by the diffusion.
    handleDiffusionError :: Network.Failure -> IO a
    handleDiffusionError full =
      case full of
        Network.DiffusionError e
          | Just e' <- fromException @SomeAsyncException e
          -> rethrowAsyncExceptions e'

          | Just e' <- fromException @ExitCode e
          -> rethrowExitCode e'

        _ -> handleException full

    -- Print all other exceptions
    handleSomeException :: SomeException -> IO a
    handleSomeException = handleException

    --
    -- utils
    --

    -- A helper function to handle an exception.
    handleException :: Exception e => e -> IO a
    handleException e = do
      hFlush stdout
      progname <- getProgName
      hPutStr stderr (renderException progname e)
      throwIO (ExitFailure 1)

    -- Print the human-readable output of 'displayException' if it differs
    -- from the default output (of 'show'), so that the user/sysadmin
    -- sees something readable in the log.
    renderException :: Exception e => String -> e -> String
    renderException progname e
      | showOutput /= displayOutput
      = showOutput ++ "\n\n" ++ progname ++ ": " ++ displayOutput

      | otherwise
      = "\n" ++ progname ++ ": " ++ showOutput
      where
        showOutput    = show e
        displayOutput = displayException e
