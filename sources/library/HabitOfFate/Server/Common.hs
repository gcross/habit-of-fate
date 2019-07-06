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
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE UnicodeSyntax #-}

module HabitOfFate.Server.Common where

import HabitOfFate.Prelude

import Control.Concurrent.MVar (MVar)
import Control.Concurrent.STM.TVar (TVar, readTVarIO)
import Data.Aeson (FromJSON(..), ToJSON(..))
import qualified Data.Text.Lazy as Lazy
import Data.Time.Clock (UTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Time.LocalTime (LocalTime)
import Data.UUID (UUID, fromText)
import Network.HTTP.Types.Status (badRequest400)
import Text.Blaze.Html.Renderer.Text (renderHtml)
import Text.Blaze.Html5 (Html, (!), toHtml)
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A
import Web.Scotty (ActionM, Parsable(..))
import qualified Web.Scotty as Scotty

import HabitOfFate.Data.Account

instance Parsable UUID where
  parseParam = view strict >>> fromText >>> maybe (Left "badly formed UUID") Right

newtype Cookie = Cookie Text deriving (Eq,FromJSON,Ord,Parsable,Read,Show,ToJSON)

data Environment = Environment
  { accounts_tvar ∷ TVar (Map Username (TVar Account))
  , accounts_changed_signal ∷ MVar ()
  , cookies_tvar ∷ TVar (Map Cookie (UTCTime, Username))
  , expirations_tvar ∷ TVar (Set (UTCTime, Cookie))
  , test_mode ∷ Bool
  }

readTVarMonadIO ∷ MonadIO m ⇒ TVar α → m α
readTVarMonadIO = readTVarIO >>> liftIO

renderLocalTime ∷ LocalTime → H.Html
renderLocalTime time =
  foldMap
    (
      (\fmt → formatTime defaultTimeLocale fmt time)
      >>>
      H.toHtml
      >>>
      H.div
    )
    ["%D", "%I:%M%P"]

paramGuardingAgainstMissing ∷ Parsable α ⇒ Lazy.Text → ActionM α
paramGuardingAgainstMissing name =
  Scotty.param name
  `Scotty.rescue`
  (\_ → do
    Scotty.status badRequest400
    Scotty.text $ name ⊕ " was not given"
    Scotty.finish
   )

data Device = Desktop | Mobile

getDevice ∷ ActionM Device
getDevice =
  Scotty.header "User-Agent" <&> \case
    Nothing → Desktop
    Just user_agent
      | any (`Lazy.isInfixOf` user_agent) ["Android", "iPhone", "Opera Mini"] → Mobile
      | otherwise → Desktop

renderPage ∷ Text → (Device → [Text]) → [Text] → Maybe Text → (Device → Html) → Device → Html
renderPage title stylesheetsFor scripts maybe_onload contentFor device =
  H.docTypeHtml $ do
    H.head $ do
      H.title $ toHtml title
      H.link ! A.href "https://fonts.googleapis.com/css?family=Gloria+Hallelujah" ! A.rel "stylesheet"
      let common_stylesheet = case device of
            Desktop → "common_desktop"
            Mobile → "common_mobile"
      forM_ ("normalize":common_stylesheet:stylesheetsFor device) $ \stylesheet →
        H.link
          ! A.rel "stylesheet"
          ! A.type_ "text/css"
          ! A.href (H.toValue $ mconcat ["/css/", stylesheet, ".css"])
      forM_ scripts $ \script →
        H.script
          ! A.rel "script"
          ! A.type_ "text/javascript"
          ! A.src (H.toValue $ mconcat ["/js/", script, ".js"])
          $ mempty
      H.meta ! A.name "viewport" ! A.content "initial-scale=1"
    ((H.body & maybe identity (\onload → (!A.onload (H.toValue onload))) maybe_onload) $ contentFor device)

generateTopHTML ∷ Device → Html → Html
generateTopHTML device content = H.div ! A.class_ "top" $ do
  H.div ! A.class_ "logo" $ H.img ! A.src "/images/logo.svgz" ! A.width "100%"
  case device of
    Desktop → do
      H.div ! A.class_ "left" $ H.img ! A.src "/images/treasure-chest.svgz" ! A.width "100%"
      H.div ! A.class_ "right" $ H.img ! A.src "/images/grave.svgz" ! A.width "100%"
    Mobile → pure ()
  H.div ! A.class_ "content" $ content

renderTopOnlyPage ∷ Text → (Device → [Text]) → [Text] → Maybe Text → (Device → Html) → Device → Html
renderTopOnlyPage title stylesheetsFor scripts maybe_onload contentFor =
  renderPage title stylesheetsFor scripts maybe_onload $
    \device → generateTopHTML device (contentFor device)
