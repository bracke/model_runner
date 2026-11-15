with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Ada_Quality;
with Ada_Quality.Checks;
with Ada_Quality.Indicators;
with Ada_Quality.Policy;
with Ada_Quality.Types;
with Project_Tools.Files;

with Model_Runner.Code_Health.Diagnostics;
with Model_Runner.Code_Health.Providers;

package body Model_Runner.Code_Health.Ada_Quality_Adapter is

   use Standard.Ada.Strings.Unbounded;

   package D renames Model_Runner.Code_Health.Diagnostics;
   package E renames Model_Runner.Errors;
   package P renames Model_Runner.Code_Health.Providers;
   package Q renames Ada_Quality;
   package QT renames Ada_Quality.Types;

   function Trim (Text : String) return String is
     (Standard.Ada.Strings.Fixed.Trim (Text, Standard.Ada.Strings.Both));

   overriding function Version (Self : Instance) return String is
   begin
      pragma Unreferenced (Self);
      return Q.Version;
   end Version;

   function Severity_Of (Value : QT.Severity) return Diagnostic_Severity is
     (case Value is
         when QT.Info     => Information,
         when QT.Low      => Information,
         when QT.Medium   => Warning,
         when QT.High     => Error,
         when QT.Critical => Critical);

   function Remediation_Of (Indicator, Rule : String) return String is
   begin
      if Indicator = "SRC-01" then
         return "Reformat the source within the configured line-width policy";
      elsif Indicator = "SRC-02" then
         return "Rename the source or unit so its Ada library-unit name matches";
      elsif Indicator = "SRC-03" then
         return "Refactor the reported subprogram or add an authorized, specific review waiver";
      elsif Indicator = "SRC-04" then
         return "Remove tabs and trailing whitespace from the reported source line";
      elsif Indicator = "SRC-05" or else Rule = "broad-handler" then
         return "Handle expected exceptions explicitly or document an audited exception boundary";
      elsif Indicator = "SRC-06" then
         return "Split the source file or add an authorized, specific size waiver";
      elsif Indicator = "SEC-01" then
         return "Remove the embedded credential and load the value from an approved secret source";
      elsif Indicator = "SEC-02" then
         return "Use the approved argument-based process API instead of shell-oriented execution";
      else
         return "Correct the reported ada_quality source-policy violation";
      end if;
   end Remediation_Of;

   overriding procedure Analyze_Changed_Sources
     (Self          : in out Instance;
      Project_Root  : String;
      Changed       : String_Lists.Vector;
      Configuration : String;
      Snapshot      : String;
      Result        : out Model_Runner.Code_Health.Ada.Source_Analysis;
      Status        : out E.Error_Info)
   is
      pragma Unreferenced (Self, Configuration);
      Policy  : constant Q.Policy.Quality_Policy := Q.Policy.Default;
      Paths   : Project_Tools.Files.Path_List (1 .. Natural (Changed.Length));
      Metrics : Q.Checks.Source_Analysis;
      Registry : constant Q.Indicators.Descriptor_Array := Q.Indicators.Registry;
   begin
      Result := (others => <>);
      if Changed.Is_Empty then
         Status := E.Make (E.Framework_Schema_Violation);
         E.Add_Text (Status, "name", "ada_quality.changed");
         E.Add_Text (Status, "detail", "change-scoped source analysis requires at least one source");
         return;
      end if;
      for Index in Paths'Range loop
         Paths (Index) := To_Unbounded_String (Changed.Element (Index));
      end loop;

      Metrics := Q.Checks.Analyze_Changed_Sources (Project_Root, Paths, Policy);
      for Finding of Metrics.Findings loop
         declare
            Indicator : constant String := QT.Image (Finding.Indicator);
            Rule      : constant String := To_String (Finding.Rule);
            Version   : constant Positive := Registry (Finding.Indicator).Version;
            Item      : constant D.Diagnostic :=
              (Provider    => To_Unbounded_String ("ada"),
               Rule_Id     => To_Unbounded_String (Indicator & "/" & Rule),
               Severity    => Severity_Of (Finding.Level),
               Path        => Finding.Relative_Path,
               Line        => Finding.Line,
               Column      => 0,
               Message     => Finding.Message,
               Explanation => To_Unbounded_String
                 ("ada_quality " & Indicator & " indicator version " & Trim (Positive'Image (Version))),
               Remediation => To_Unbounded_String (Remediation_Of (Indicator, Rule)),
               Evidence_Id => Finding.Fingerprint,
               Native_Code => Finding.Rule,
               Snapshot    => To_Unbounded_String (Snapshot),
               Provenance  => ["ada_quality:" & Q.Version & ":" & Indicator],
               others      => <>);
         begin
            D.Append_Validated (Result.Diagnostics, Item, Status, Project_Root);
            if not E.Is_Ok (Status) then
               return;
            end if;
         end;
      end loop;

      for Path of Changed loop
         if not Result.Files_Analyzed.Contains (Path) then
            Result.Files_Analyzed.Append (Path);
         end if;
      end loop;
      Result.Toolchain_Fingerprint.Append ("ada_quality:" & Q.Version);
      Result.Toolchain_Fingerprint.Append ("policy:" & Q.Policy.Fingerprint (Policy));
      Result.Check :=
        (Identifier => To_Unbounded_String ("ada-quality-source"),
         Status     => (if D.Length (Result.Diagnostics) = 0 then P.Check_Passed else P.Check_Findings),
         Required   => True,
         Detail     => To_Unbounded_String
           (Natural'Image (Metrics.File_Count) & " changed Ada sources analyzed with shared indicators"),
         Evidence   => To_Unbounded_String (Q.Policy.Fingerprint (Policy)));
      Status := E.Success;
   exception
      when Failure : others =>
         Result := (others => <>);
         Status := E.Unexpected (Failure, "running change-scoped ada_quality source analysis");
   end Analyze_Changed_Sources;

end Model_Runner.Code_Health.Ada_Quality_Adapter;
