with Ada.Strings.Unbounded;

package body Model_Runner.Code_Health.Ada_Profiles is

   use Ada.Strings.Unbounded;
   package P renames Model_Runner.Code_Health.Profiles;

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
           ("ada-affected-tests", Focused, P.Dependency_Scope, 120,
            Dependencies => ["ada-project"]));
   end Add_Defaults;

end Model_Runner.Code_Health.Ada_Profiles;
