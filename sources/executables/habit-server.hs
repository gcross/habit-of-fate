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

{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UnicodeSyntax #-}

module Main where

import HabitOfFate.Prelude

import qualified Data.ByteString as BS
import Data.Text.IO
import Data.Yaml hiding (Parser, (.=))
import Network.Wai.Handler.Warp hiding (run)
import Network.Wai.Handler.WarpTLS
import Options.Applicative
import System.Directory
import System.Exit

import HabitOfFate.Logging
import HabitOfFate.Server

data Configuration = Configuration
  { port ∷ Int
  , data_path ∷ FilePath
  , certificate_path ∷ FilePath
  , key_path ∷ FilePath
  }

exitFailureWithMessage ∷ Text → IO α
exitFailureWithMessage message = do
  putStrLn message
  exitFailure

main ∷ IO ()
main = do
  let configuration_parser ∷ Parser Configuration
      configuration_parser = Configuration
        <$> option auto (mconcat
              [ metavar "PORT"
              , help "Port to listen on."
              , long "port"
              , short 'p'
              , value 8081
              ])
        <*> (strOption $ mconcat
              [ metavar "FILE"
              , help "Path to the game data."
              , long "data"
              , action "file"
              ]
            )
        <*> (strOption $ mconcat
              [ metavar "FILE"
              , help "Path to the certificate file."
              , long "cert"
              , long "certificate"
              , action "file"
              ]
            )
        <*> (strOption $ mconcat
              [ metavar "FILE"
              , help "Path to the key file."
              , long "key"
              , action "file"
              ]
            )
  Configuration{..} ←
    execParser $ info
      (configuration_parser <**> helper)
      (fullDesc <> header "habit-server - server program for habit-of-fate"
      )
  logIO $ "Listening on port " ⊕ show port
  logIO $ "Certificate file is located at " ⊕ certificate_path
  logIO $ "Key file is located at " ⊕ key_path

  initial_accounts ←
    doesFileExist data_path
    >>=
    bool
      (do logIO $ "Creating new data file at " ⊕ data_path
          pure mempty
      )
      (do logIO $ "Reading existing data file at " ⊕ data_path
          BS.readFile data_path >>= (decodeEither >>> either error pure)
      )
  makeApp initial_accounts (encodeFile data_path) >>=
    runTLS
      (tlsSettings certificate_path key_path)
      (setPort port defaultSettings)
