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

{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE UnicodeSyntax #-}

module HabitOfFate.Server.Common where

import HabitOfFate.Prelude

import Control.Concurrent.STM.TVar (TVar, readTVarIO)
import Control.Concurrent.STM.TMVar (TMVar)
import Data.Aeson (FromJSON(..), ToJSON(..))
import qualified Data.Text.Lazy as Lazy
import Data.Time.Clock (UTCTime)
import Data.UUID (UUID, fromText)
import Network.HTTP.Types.Status (badRequest400)
import Network.Wai (rawPathInfo, rawQueryString, requestMethod)
import Web.Scotty (ActionM, Parsable(..))
import qualified Web.Scotty as Scotty

import HabitOfFate.Data.Account
import HabitOfFate.Logging

instance Parsable UUID where
  parseParam = view strict >>> fromText >>> maybe (Left "badly formed UUID") Right

newtype Cookie = Cookie Text deriving (Eq,FromJSON,Ord,Parsable,Read,Show,ToJSON)

data Environment = Environment
  { accounts_tvar ∷ TVar (Map Username (TVar Account))
  , cookies_tvar ∷ TVar (Map Cookie (UTCTime, Username))
  , expirations_tvar ∷ TVar (Set (UTCTime, Cookie))
  , write_request_var ∷ TMVar ()
  , createAndReturnCookie ∷ Username → ActionM ()
  }

readTVarMonadIO ∷ MonadIO m ⇒ TVar α → m α
readTVarMonadIO = readTVarIO >>> liftIO

logRequest ∷ ActionM ()
logRequest = do
  r ← Scotty.request
  logIO [i|URL requested: #{requestMethod r} #{rawPathInfo r}#{rawQueryString r}|]

paramGuardingAgainstMissing ∷ Parsable α ⇒ Lazy.Text → ActionM α
paramGuardingAgainstMissing name =
  Scotty.param name
  `Scotty.rescue`
  (\_ → do
    Scotty.status badRequest400
    Scotty.text $ name ⊕ " was not given"
    Scotty.finish
   )
