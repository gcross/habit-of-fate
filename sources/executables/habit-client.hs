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
{-# LANGUAGE UnicodeSyntax #-}

module Main where

import HabitOfFate.Prelude hiding (argument)

import Options.Applicative

import HabitOfFate.API (SecureMode(Secure))
import HabitOfFate.Client (Configuration(..), doMain)

configuration_parser ∷ Parser Configuration
configuration_parser = Configuration
  <$> strArgument (mconcat
        [ metavar "HOSTNAME"
        , help "Name of the host to connect to."
        , value "localhost"
        ])
  <*> argument auto (mconcat
        [ metavar "PORT"
        , help "Port to connect to."
        , value 8081
        ])
  <*> switch (mconcat
        [ help "Create a new account."
        , long "create"
        , short 'c'
        ])

main ∷ IO ()
main =
  (
    execParser
    $
    info
      (configuration_parser <**> helper)
      (
          fullDesc
        ⊕ header "habit-client - a client program for habit-of-fate"
      )
  )
  >>=
  doMain Secure
