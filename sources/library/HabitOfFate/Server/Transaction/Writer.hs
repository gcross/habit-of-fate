{-
    Habit of Fate, a game to incentivize habit formation.
    Copyright (C) 2017 Gregory Crosswhite

    This program is free software: you can redistribute it and/or modify
    it under version 3 of the terms of the GNU Affero General Public License.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
-}

{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE UnicodeSyntax #-}

module HabitOfFate.Server.Transaction.Writer where

import HabitOfFate.Prelude

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar (readTVar, writeTVar)
import Control.Concurrent.STM.TMVar (tryPutTMVar)
import Control.Monad.Operational (Program, interpretWithMonad)
import qualified Control.Monad.Operational as Operational
import Control.Monad.Random (RandT, StdGen, evalRandT, newStdGen)
import Network.HTTP.Types.Status (Status)
import Web.Scotty (ActionM)
import qualified Web.Scotty as Scotty

import HabitOfFate.Data.Account
import HabitOfFate.Logging
import HabitOfFate.Server.Actions.Queries
import HabitOfFate.Server.Actions.Results
import HabitOfFate.Server.Common
import HabitOfFate.Server.Transaction.Common

data WriterInstruction α where
  WriterCommonInstruction ∷ CommonInstruction α → WriterInstruction α
  WriterGetAccountInstruction ∷ WriterInstruction Account
  WriterPutAccountInstruction ∷ Account → WriterInstruction ()

newtype WriterTransaction α = WriterTransaction
  { unwrapWriterTransaction ∷ Program WriterInstruction α }
  deriving (Applicative, Functor, Monad)

instance ActionMonad WriterTransaction where
  singletonCommon = WriterCommonInstruction >>> Operational.singleton >>> WriterTransaction

instance MonadState Account WriterTransaction where
  get = Operational.singleton WriterGetAccountInstruction |> WriterTransaction
  put = WriterPutAccountInstruction >>> Operational.singleton >>> WriterTransaction

writerWith ∷ (∀ α. String → ActionM α) → Environment → WriterTransaction TransactionResult → ActionM ()
writerWith actionWhenAuthFails (environment@Environment{..}) (WriterTransaction program) = do
  logRequest
  (username, account_tvar) ← authorizeWith actionWhenAuthFails environment
  params_ ← Scotty.params
  body_ ← Scotty.body
  let interpret ∷
        WriterInstruction α →
        StateT Account (ExceptT Status (RandT StdGen (Writer (Seq String)))) α
      interpret (WriterCommonInstruction GetBodyInstruction) = pure body_
      interpret (WriterCommonInstruction GetParamsInstruction) = pure params_
      interpret (WriterCommonInstruction (RaiseStatusInstruction s)) = throwError s
      interpret (WriterCommonInstruction (LogInstruction message)) =
        void ([i|[#{unwrapUsername username}]: #{message}|] |> singleton |> tell)
      interpret WriterGetAccountInstruction = get
      interpret (WriterPutAccountInstruction new_account) = put new_account
  initial_generator ← liftIO newStdGen
  (redirect_or_content, logs) ← atomically >>> liftIO $ do
    old_account ← readTVar account_tvar
    let (error_or_result, logs) =
          interpretWithMonad interpret program
            |> flip runStateT old_account
            |> runExceptT
            |> flip evalRandT initial_generator
            |> runWriter
    case error_or_result of
      Left status_ → pure (Right (status_, Nothing), logs)
      Right (result, new_account) → do
        writeTVar account_tvar new_account
        writeTVar accounts_changed_flag True
        pure $ case result of
          RedirectsTo href → (Left href, logs)
          TransactionResult status_ content → (Right (status_, Just content), logs)
  traverse_ logIO logs
  case redirect_or_content of
    Left href → Scotty.redirect href
    Right (status_, maybe_content) → do
      setStatusAndLog status_
      maybe (pure ()) setContent maybe_content

apiWriter ∷ Environment → WriterTransaction TransactionResult → ActionM ()
apiWriter = writerWith (finishWithStatusMessage 403)

webWriter ∷ Environment → WriterTransaction TransactionResult → ActionM ()
webWriter = writerWith (const $ Scotty.redirect "/login")
