{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE UnicodeSyntax #-}

module HabitOfFate.Accounts where

import HabitOfFate.Prelude

import Data.Aeson
import qualified Data.ByteString as BS
import System.Directory
import System.Environment
import System.FilePath

import HabitOfFate.Account

type Accounts = Map String Account

readAccounts ∷ FilePath → IO Accounts
readAccounts = BS.readFile >=> either error return . decodeEither

writeAccounts ∷ FilePath → Accounts → IO ()
writeAccounts = encodeFile
