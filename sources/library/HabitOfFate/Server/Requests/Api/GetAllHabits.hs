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

{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE UnicodeSyntax #-}

module HabitOfFate.Server.Requests.Api.GetAllHabits (handleGetAllHabitsApi) where

import HabitOfFate.Prelude

import Network.HTTP.Types.Status (ok200)
import Web.Scotty (ScottyM)
import qualified Web.Scotty as Scotty

import HabitOfFate.Data.Account
import HabitOfFate.Server.Common
import HabitOfFate.Server.Transaction.Common
import HabitOfFate.Server.Transaction.Reader

handleGetAllHabitsApi ∷ Environment → ScottyM ()
handleGetAllHabitsApi environment = do
  Scotty.get "/api/habits" <<< apiReader environment $ do
    log "Requested all habits."
    view habits_ >>= returnJSON ok200
