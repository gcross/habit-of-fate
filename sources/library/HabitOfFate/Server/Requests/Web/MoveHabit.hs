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
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE UnicodeSyntax #-}

module HabitOfFate.Server.Requests.Web.MoveHabit (handler) where

import HabitOfFate.Prelude

import Network.HTTP.Types.Status (temporaryRedirect307)
import Web.Scotty (ScottyM)
import qualified Web.Scotty as Scotty

import HabitOfFate.Data.Account
import HabitOfFate.Data.ItemsSequence
import HabitOfFate.Server.Common
import HabitOfFate.Server.Transaction

handler ∷ Environment → ScottyM ()
handler environment = do
  Scotty.post "/habits/:habit_id/move" action
  Scotty.post "/habits/:habit_id/move/:new_index" action
 where
  action = webTransaction environment $ do
    habit_id ← getParam "habit_id"
    new_index ← getParam "new_index" <&> (\n → n-1)
    log [i|Web POST request to move habit with id #{habit_id} to index #{new_index}.|]
    old_habits ← use habits_
    case moveWithIdToIndex habit_id new_index old_habits of
      Left exc → log [i|Exception moving habit: #{exc}|]
      Right new_habits → habits_ .= new_habits
    pure $ redirectsToResult temporaryRedirect307 "/habits"
