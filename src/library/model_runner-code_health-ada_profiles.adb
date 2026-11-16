with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

package body Model_Runner.Code_Health.Ada_Profiles is

   use Ada.Strings.Unbounded;
   package P renames Model_Runner.Code_Health.Profiles;
   package Providers renames Model_Runner.Code_Health.Providers;
   package E renames Model_Runner.Errors;

   function Check
     (Identifier   : String;
      Level        : Check_Level;
      Scope        : P.Scope_Kind;
      Timeout      : Positive;
      Required     : Boolean := True;
      Tools        : String_Lists.Vector := String_Lists.Empty_Vector;
      Dependencies : String_Lists.Vector := String_Lists.Empty_Vector) return P.Check_Definition is
   begin
      return
        (Identifier        => To_Unbounded_String (Identifier),
         Provider          => To_Unbounded_String ("ada"),
         Level             => Level,
         Required          => Required,
         Block_On          => Error,
         Scope             => Scope,
         Timeout_Seconds   => Timeout,
         Dependencies      => Dependencies,
         Cache             => P.Exact_Inputs,
         Tool_Requirements => Tools,
         Output_Limit      => 8 * 1024);
   end Check;

   procedure Add_Defaults (To : in out P.Profile_Set) is
   begin
      P.Add
        (To, "ada-fast",
         Check ("ada-syntax", Fast, P.Changed_Files, 10, Tools => ["gnatmake"]));
      P.Add
        (To, "ada-fast",
         Check ("ada-quality-source", Fast, P.Changed_Files, 10));
      P.Add
        (To, "ada-fast",
         Check ("ada-language-server", Fast, P.Changed_Files, 10, Required => False));
      P.Add
        (To, "ada-fast",
         Check ("ada-project", Fast, P.Changed_Files, 10, Tools => ["gprbuild"]));
      P.Add
        (To, "ada-fast",
         Check ("ada-manifest", Fast, P.Changed_Files, 10, Tools => ["alr"]));

      P.Add
        (To, "ada-focused",
         Check ("ada-syntax", Focused, P.Changed_Files, 30, Tools => ["gnatmake"]));
      P.Add
        (To, "ada-focused",
         Check ("ada-quality-source", Focused, P.Changed_Files, 30));
      P.Add
        (To, "ada-focused",
         Check ("ada-language-server", Focused, P.Changed_Files, 30, Required => False));
      P.Add
        (To, "ada-focused",
         Check
           ("ada-project", Focused, P.Dependency_Scope, 120,
            Tools => ["gprbuild"], Dependencies => ["ada-syntax"]));
      P.Add
        (To, "ada-focused",
         Check
           ("ada-contracts", Focused, P.Dependency_Scope, 120,
            Required => False, Tools => ["gnatprove"],
            Dependencies => ["ada-project"]));
      P.Add
        (To, "ada-focused",
         Check
           ("ada-affected-tests", Focused, P.Dependency_Scope, 120,
            Dependencies => ["ada-project"]));
      P.Add
        (To, "ada-focused",
         Check ("ada-manifest", Focused, P.Dependency_Scope, 120, Tools => ["alr"]));
   end Add_Defaults;

   procedure Resolve
     (Names  : String;
      Level  : Check_Level;
      Result : out Providers.Requested_Check_Lists.Vector;
      Status : out E.Error_Info)
   is
      First : Natural := Names'First;

      procedure Add (Identifier : String; Required : Boolean := True) is
         Timeout : constant Natural := (if Level = Fast then 10 else 120);
         Tools   : String_Lists.Vector;
      begin
         for Existing of Result loop
            if To_String (Existing.Identifier) = Identifier then
               return;
            end if;
         end loop;
         if Identifier = "ada-syntax" then
            Tools.Append ("gnatmake");
         elsif Identifier = "ada-project" then
            Tools.Append ("gprbuild");
         elsif Identifier = "ada-contracts" then
            Tools.Append ("gnatprove");
         elsif Identifier = "ada-manifest" then
            Tools.Append ("alr");
         end if;
         Result.Append
           (Providers.Requested_Check'
              (Identifier        => To_Unbounded_String (Identifier),
               Provider          => To_Unbounded_String ("ada"),
               Required          => Required,
               Block_On          => Error,
               Scope             =>
                 (if Level = Fast then Providers.Changed_Files
                  else Providers.Dependency_Scope),
               Timeout_Seconds   => Timeout,
               Dependencies      => String_Lists.Empty_Vector,
               Cacheable         => Identifier not in "ada-language-server" | "ada-affected-tests",
               Tool_Requirements => Tools,
               Output_Limit      => 8 * 1024));
      end Add;

      procedure Refuse (Name, Detail : String) is
      begin
         Status := E.Make (E.Framework_Schema_Violation);
         E.Add_Text (Status, "name", "code_health.check");
         E.Add_Text (Status, "value", Name);
         E.Add_Text (Status, "detail", Detail);
      end Refuse;

      procedure Take (Raw : String) is
         Name : constant String := Ada.Characters.Handling.To_Lower
           (Ada.Strings.Fixed.Trim (Raw, Ada.Strings.Both));
      begin
         if Name = "" then
            return;
         elsif Name = "syntax" or else Name = "ada-syntax" then
            Add ("ada-syntax");
         elsif Name in "formatting" | "hygiene" | "security" | "complexity"
           or else Name = "ada-quality-source"
         then
            Add ("ada-quality-source");
         elsif Name in "language_server" | "language-server" | "lsp"
           or else Name = "ada-language-server"
         then
            Add ("ada-language-server", Required => False);
         elsif Name in "build" | "project" or else Name = "ada-project" then
            Add ("ada-project");
         elsif Name in "contracts" | "proof" | "gnatprove"
           or else Name = "ada-contracts"
         then
            Add ("ada-contracts", Required => False);
         elsif Name in "affected_tests" | "affected-tests" | "tests"
           or else Name = "ada-affected-tests"
         then
            Add ("ada-affected-tests");
         elsif Name in "manifest" | "dependencies" or else Name = "ada-manifest" then
            Add ("ada-manifest");
         else
            Refuse (Name, "unknown Ada Code Health check");
         end if;
      end Take;
   begin
      Result.Clear;
      Status := E.Success;
      if Names = "" then
         Refuse (Names, "the enabled profile has no checks");
         return;
      end if;
      for Index in Names'Range loop
         if Names (Index) in ',' | ASCII.LF | ASCII.CR then
            if Index > First then
               Take (Names (First .. Index - 1));
               if E.Is_Error (Status) then
                  return;
               end if;
            end if;
            First := Index + 1;
         end if;
      end loop;
      if First <= Names'Last then
         Take (Names (First .. Names'Last));
      end if;
      if E.Is_Error (Status) then
         return;
      elsif Result.Is_Empty then
         Refuse (Names, "the enabled profile has no checks");
      elsif Level = Fast
        and then (for some Check of Result =>
                    To_String (Check.Identifier) = "ada-affected-tests")
      then
         Refuse (Names, "affected tests require a focused assessment");
      else
         for Index in Result.First_Index .. Result.Last_Index loop
            declare
               Check : Providers.Requested_Check := Result.Element (Index);
            begin
               if To_String (Check.Identifier) = "ada-project"
                 and then (for some Item of Result =>
                             To_String (Item.Identifier) = "ada-syntax")
               then
                  Check.Dependencies.Append ("ada-syntax");
               elsif To_String (Check.Identifier) = "ada-contracts"
                 and then (for some Item of Result =>
                             To_String (Item.Identifier) = "ada-project")
               then
                  Check.Dependencies.Append ("ada-project");
               elsif To_String (Check.Identifier) = "ada-affected-tests"
                 and then (for some Item of Result =>
                             To_String (Item.Identifier) = "ada-project")
               then
                  Check.Dependencies.Append ("ada-project");
               end if;
               Result.Replace_Element (Index, Check);
            end;
         end loop;
         Status := E.Success;
      end if;
   end Resolve;

end Model_Runner.Code_Health.Ada_Profiles;
