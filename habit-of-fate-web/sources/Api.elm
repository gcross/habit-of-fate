module Api exposing (..)


import EveryDict exposing (EveryDict)
import Formatting exposing ((<>), print, s, string)
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)
import List exposing (foldr)
import Monocle.Lens exposing (..)
import Task exposing (Task, fail, succeed)
import Uuid exposing (Uuid)

import Habit exposing (..)


type ApiResult result = UnexpectedError Http.Error | ExpectedResult result


toCmd : Task Http.Error result -> Cmd (ApiResult result)
toCmd =
  Task.attempt (\result ->
    case result of
      Err error -> UnexpectedError error
      Ok value -> ExpectedResult value
  )


handleErrorStatusCode : Int -> α -> Task Http.Error α -> Task Http.Error α
handleErrorStatusCode code value =
  Task.onError (\error ->
    case error of
      Http.BadStatus response ->
        if response.status.code == code
          then succeed value
          else fail error
      _ -> fail error
  )


--------------------------------------------------------------------------------
-------------------------------- Login-related ---------------------------------
--------------------------------------------------------------------------------


type alias Token = String


type alias LoginInformation = { username: String, password: String }


encodeLoginInformation : LoginInformation -> Http.Body
encodeLoginInformation login_information =
  Http.stringBody
    "application/x-www-form-urlencoded"
    (print
      (s "username=" <> string <> s "&password=" <> string)
      (Http.encodeUri login_information.username)
      (Http.encodeUri login_information.password)
    )


-------------------------------- Create Account --------------------------------


type CreateAccountResult = AccountAlreadyExists | AccountCreated Token


createAccountTask : LoginInformation -> Task Http.Error CreateAccountResult
createAccountTask login_information =
  (
    Http.request
      { method = "POST"
      , headers = []
      , url = "api/create"
      , body = encodeLoginInformation login_information
      , expect = Http.expectString
      , timeout = Nothing
      , withCredentials = False
      }
  )
  |> Http.toTask
  |> Task.map AccountCreated
  |> handleErrorStatusCode 409 AccountAlreadyExists


createAccountCmd : LoginInformation -> Cmd (ApiResult CreateAccountResult)
createAccountCmd = createAccountTask >> toCmd


------------------------------------ Login -------------------------------------


type LoginResult = NoSuchAccount | InvalidPassword | LoginSuccessful Token


loginTask : LoginInformation -> Task Http.Error LoginResult
loginTask login_information =
  (
    Http.request
      { method = "POST"
      , headers = []
      , url = "api/login"
      , body = encodeLoginInformation login_information
      , expect = Http.expectString
      , timeout = Nothing
      , withCredentials = False
      }
  )
  |> Http.toTask
  |> Task.map LoginSuccessful
  |> handleErrorStatusCode 403 InvalidPassword
  |> handleErrorStatusCode 404 NoSuchAccount


loginCmd : LoginInformation -> Cmd (ApiResult LoginResult)
loginCmd = loginTask >> toCmd


--------------------------------------------------------------------------------
-------------------------------- Habit-related ---------------------------------
--------------------------------------------------------------------------------


name : Lens Habit String
name =
  let get x = x.name
      set y x = {x | name = y}
  in Lens get set


scaleFactor : Scale -> Float
scaleFactor scale =
  case scale of
    VeryLow -> 1/4
    Low -> 1/2
    Medium -> 1
    High -> 2
    VeryHigh -> 4


makeHabitUrl : Uuid -> String
makeHabitUrl = Uuid.toString >> print (s "/api/habits/" <> string)


uuid_decoder : Decoder Uuid
uuid_decoder =
  Decode.string
  |> Decode.andThen (\s ->
      case Uuid.fromString s of
        Nothing -> Decode.fail "invalid UUID"
        Just uuid -> Decode.succeed uuid
     )


credit_decoder : Decoder Credits
credit_decoder =
  Decode.map2
    (\success failure -> { success = success, failure = failure })
    (Decode.field "success" Decode.float)
    (Decode.field "failure" Decode.float)


scale_decoder : Decoder Scale
scale_decoder =
  Decode.string
  |> Decode.andThen (\s ->
      case s of
        "very low" -> Decode.succeed VeryLow
        "low" -> Decode.succeed Low
        "medium" -> Decode.succeed Medium
        "high" -> Decode.succeed High
        "very high" -> Decode.succeed VeryHigh
        _ -> Decode.fail "invalid scale value"
     )


habit_decoder : Decoder Habit
habit_decoder =
  Decode.map3
    (\name importance difficulty ->
       { name = name,
         importance = importance,
         difficulty = difficulty
       }
    )
    (Decode.field "name" Decode.string)
    (Decode.field "importance" scale_decoder)
    (Decode.field "difficulty" scale_decoder)


habits_decoder : Decoder Habits
habits_decoder =
  Decode.keyValuePairs habit_decoder
  |> Decode.andThen (
      foldr
        (\(uuid_string, habit) decoded ->
          case Uuid.fromString uuid_string of
            Nothing -> Decode.fail ("Invalid UUID: " ++ uuid_string)
            Just uuid -> Decode.map (\pairs -> (uuid, habit)::pairs) decoded
        )
        (Decode.succeed [])
     )
  |> Decode.map EveryDict.fromList


encodeCredits : Credits -> Value
encodeCredits credits =
  Encode.object
  [ ("success", Encode.float credits.success)
  , ("failure", Encode.float credits.failure)
  ]


encodeScale : Scale -> Value
encodeScale scale =
  case scale of
    VeryLow -> Encode.string "very low"
    Low -> Encode.string "low"
    Medium -> Encode.string "medium"
    High -> Encode.string "high"
    VeryHigh -> Encode.string "very high"


encodeHabit : Habit -> Value
encodeHabit habit =
  Encode.object
  [ ("name", Encode.string habit.name)
  , ("importance", encodeScale habit.importance)
  , ("difficulty", encodeScale habit.difficulty)
  ]


---------------------------------- Put Habit -----------------------------------


type PutHabitResult = HabitCreated | HabitReplaced


putHabitTask : Token -> Uuid -> Habit -> Task Http.Error PutHabitResult
putHabitTask token uuid habit =
  (
    Http.request
      { method = "PUT"
      , headers = [Http.header "Authorization" ("Bearer " ++ token)]
      , url = makeHabitUrl uuid
      , body = Http.jsonBody (encodeHabit habit)
      , expect = Http.expectStringResponse
          (\response ->
             case response.status.code of
               201 -> Ok HabitCreated
               204 -> Ok HabitReplaced
               _ -> Err ("Unexpected response: " ++ toString response.status)
          )
      , timeout = Nothing
      , withCredentials = False
      }
  )
  |> Http.toTask


putHabitCmd : Token -> Uuid -> Habit -> Cmd (ApiResult PutHabitResult)
putHabitCmd token uuid habit = putHabitTask token uuid habit |> toCmd


---------------------------------- Get Habit -----------------------------------


getHabitTask : Token -> Uuid -> Task Http.Error (Maybe Habit)
getHabitTask token uuid =
  (
    Http.request
      { method = "GET"
      , headers = [Http.header "Authorization" ("Bearer " ++ token)]
      , url = makeHabitUrl uuid
      , body = Http.emptyBody
      , expect = Http.expectStringResponse
          (\response ->
             case response.status.code of
               200 ->
                 response.body
                 |> Decode.decodeString habit_decoder
                 |> Result.map Just
               _ -> Err ("Unexpected response: " ++ toString response.status)
          )
      , timeout = Nothing
      , withCredentials = False
      }
  )
  |> Http.toTask
  |> handleErrorStatusCode 404 Nothing



getHabitCmd : Token -> Uuid -> Cmd (ApiResult (Maybe Habit))
getHabitCmd token uuid = getHabitTask token uuid |> toCmd


---------------------------------- Get Habits ----------------------------------


getHabitsTask : Token -> Task Http.Error Habits
getHabitsTask token =
  (
    Http.request
      { method = "GET"
      , headers = [Http.header "Authorization" ("Bearer " ++ token)]
      , url = "/api/habits"
      , body = Http.emptyBody
      , expect = Http.expectJson habits_decoder
      , timeout = Nothing
      , withCredentials = False
      }
  )
  |> Http.toTask


getHabitsCmd : Token -> Cmd (ApiResult Habits)
getHabitsCmd = getHabitsTask >> toCmd


--------------------------------- Delete Habit ---------------------------------


type DeleteHabitResult = HabitDeleted | NoHabitToDelete


deleteHabitTask : Token -> Uuid -> Task Http.Error DeleteHabitResult
deleteHabitTask token uuid =
  (
    Http.request
      { method = "DELETE"
      , headers = [Http.header "Authorization" ("Bearer " ++ token)]
      , url = makeHabitUrl uuid
      , body = Http.emptyBody
      , expect = Http.expectStringResponse
          (\response ->
             case response.status.code of
               204 -> Ok HabitDeleted
               _ -> Err ("Unexpected response: " ++ toString response.status)
          )
      , timeout = Nothing
      , withCredentials = False
      }
  )
  |> Http.toTask
  |> handleErrorStatusCode 404 NoHabitToDelete


deleteHabitCmd : Token -> Uuid -> Cmd (ApiResult DeleteHabitResult)
deleteHabitCmd token uuid = deleteHabitTask token uuid |> toCmd


--------------------------------------------------------------------------------
--------------------------------- Game-related ---------------------------------
--------------------------------------------------------------------------------


--------------------------------- Get Credits ----------------------------------


getCreditsTask : Token -> Task Http.Error Credits
getCreditsTask token =
  (
    Http.request
      { method = "GET"
      , headers = [Http.header "Authorization" ("Bearer " ++ token)]
      , url = "/api/credits"
      , body = Http.emptyBody
      , expect = Http.expectJson credit_decoder
      , timeout = Nothing
      , withCredentials = False
      }
  )
  |> Http.toTask


getCreditsCmd : Token -> Cmd (ApiResult Credits)
getCreditsCmd = getCreditsTask >> toCmd


--------------------------------- Mark Habits ----------------------------------

type alias Marks = { successes: List Uuid, failures: List Uuid }


encodeUuid : Uuid -> Value
encodeUuid = Uuid.toString >> Encode.string


encodeMarks : Marks -> Value
encodeMarks marks =
  Encode.object
  [ ("successes", marks.successes |> List.map encodeUuid |> Encode.list)
  , ("failures", marks.failures |> List.map encodeUuid |> Encode.list)
  ]


markHabitsTask : Token -> Marks -> Task Http.Error Credits
markHabitsTask token marks =
  (
    Http.request
      { method = "POST"
      , headers = [Http.header "Authorization" ("Bearer " ++ token)]
      , url = "/api/mark"
      , body = Http.jsonBody (encodeMarks marks)
      , expect = Http.expectJson credit_decoder
      , timeout = Nothing
      , withCredentials = False
      }
  )
  |> Http.toTask


markHabitsCmd : Token -> Marks -> Cmd (ApiResult Credits)
markHabitsCmd token marks = markHabitsTask token marks |> toCmd
