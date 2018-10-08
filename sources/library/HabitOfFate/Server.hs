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

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE UnicodeSyntax #-}
{-# LANGUAGE ViewPatterns #-}

module HabitOfFate.Server
  ( Username(..)
  , makeApp
  , makeAppRunningInTestMode
  ) where

import HabitOfFate.Prelude

import Control.Concurrent
import Control.Concurrent.STM
import Data.Set (minView)
import Data.Time.Clock
import GHC.Conc.Sync (unsafeIOToSTM)
import Network.HTTP.Types.Status
import Network.Wai
import System.IO (BufferMode(LineBuffering), hSetBuffering, stderr)
import qualified Web.Scotty as Scotty

import HabitOfFate.Data.Account
import HabitOfFate.Logging
import HabitOfFate.Server.Actions.Results
import HabitOfFate.Server.Common

import HabitOfFate.Server.Requests.Api.DeleteHabit
import HabitOfFate.Server.Requests.Api.GetAllHabits
import HabitOfFate.Server.Requests.Api.GetCredits
import HabitOfFate.Server.Requests.Api.GetHabit
import HabitOfFate.Server.Requests.Api.GetQuestStatus
import HabitOfFate.Server.Requests.Api.PutHabit

import HabitOfFate.Server.Requests.Web.EditAndDeleteHabit
import HabitOfFate.Server.Requests.Web.GetAllHabits
import HabitOfFate.Server.Requests.Web.GetFile
import HabitOfFate.Server.Requests.Web.GetQuestStatus
import HabitOfFate.Server.Requests.Web.MoveHabit
import HabitOfFate.Server.Requests.Web.NewHabit

import HabitOfFate.Server.Requests.LoginOrCreate
import HabitOfFate.Server.Requests.Logout
import HabitOfFate.Server.Requests.MarkHabitAndRun

--------------------------------------------------------------------------------
------------------------------ Background Threads ------------------------------
--------------------------------------------------------------------------------

cleanCookies ∷ Environment → IO α
cleanCookies Environment{..} = forever $ do
  dropped ←
    (atomically $ do
      current_time ← unsafeIOToSTM getCurrentTime
      expirations ← readTVar expirations_tvar
      case minView expirations of
        Nothing → pure False
        Just (first@(first_time, first_cookie), rest) → do
          if first_time < current_time
            then do
              unsafeIOToSTM $ logIO [i|Dropping cookie #{first} at #{current_time}.|]
              modifyTVar cookies_tvar $ deleteMap first_cookie
              writeTVar expirations_tvar rest
              pure True
            else
              pure False
    )
  unless dropped $ threadDelay (60 * 1000 * 1000)

--------------------------------------------------------------------------------
------------------------------ Server Application ------------------------------
--------------------------------------------------------------------------------

makeAppWithTestMode ∷ Bool → TVar (Map Username (TVar Account)) → TVar Bool → IO Application
makeAppWithTestMode test_mode accounts_tvar accounts_changed_flag = do
  liftIO $ hSetBuffering stderr LineBuffering

  logIO "Starting server..."

  cookies_tvar ← newTVarIO mempty
  expirations_tvar ← newTVarIO mempty

  let environment = Environment{..}

  _ ← forkIO $ cleanCookies environment

  Scotty.scottyApp $ do

    Scotty.middleware $ \runOuterMiddleware req sendResponse → do
      logIO [i|- #{requestMethod req} #{rawPathInfo req}#{rawQueryString req}|]
      runOuterMiddleware req sendResponse

    Scotty.defaultHandler $ \message → do
      logIO [i|ERROR: #{message}|]
      Scotty.status internalServerError500
      Scotty.text message

    handleGetFileWeb

    mapM_ ($ environment)
      [ handleDeleteHabitApi
      , handleNewHabitWeb -- MUST be before EditAndDeleteHabit or creating a new habit breaks
      , handleEditAndDeleteHabitWeb
      , handleGetAllHabitsApi
      , handleGetAllHabitsWeb
      , handleGetCreditsApi
      , handleGetHabitApi
      , handleGetQuestStatusApi
      , handleGetQuestStatusWeb
      , handleLoginOrCreate
      , handleLogout
      , handleMarkHabitAndRun
      , handleMoveHabitWeb
      , handlePutHabitApi
      ]

    Scotty.get "/" $ setStatusAndRedirect movedPermanently301 "/habits"

    Scotty.notFound $ do
      r ← Scotty.request
      logIO [i|URL not found! #{requestMethod r} #{rawPathInfo r}#{rawQueryString r}|]
      Scotty.next

makeApp ∷ TVar (Map Username (TVar Account)) → TVar Bool → IO Application
makeApp = makeAppWithTestMode False

makeAppRunningInTestMode ∷ TVar (Map Username (TVar Account)) → TVar Bool → IO Application
makeAppRunningInTestMode = makeAppWithTestMode True
