{-
    Habit of Fate, a game to incentivize group formation.
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
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE UnicodeSyntax #-}

module HabitOfFate.Server.Requests.Api.PutGroup (handler) where

import HabitOfFate.Prelude

import Network.HTTP.Types.Status (created201, noContent204)
import Web.Scotty (ScottyM)
import qualified Web.Scotty as Scotty

import HabitOfFate.Data.Account
import HabitOfFate.Server.Common
import HabitOfFate.Server.Transaction

handler ∷ Environment → ScottyM ()
handler environment = do
  Scotty.post "/api/groups/:group_id" <<< apiTransaction environment $ action
  Scotty.put "/api/groups/:group_id" <<< apiTransaction environment $ action
 where
  action = do
    group_id ← getParam "group_id"
    log [i|Requested to put group with id #{group_id}.|]
    group ← getBodyJSON
    group_was_there ← isJust <$> (groups_ . at group_id <<.= Just group)
    noContentResult >>> pure $
      if group_was_there
        then noContent204
        else created201
