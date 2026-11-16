with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Model_Runner.Code_Health.Diagnostics;
with Model_Runner.Code_Health.Providers;

package body Model_Runner.Code_Health.Ada_LSP_Adapter is

   use Standard.Ada.Strings.Unbounded;

   package D renames Model_Runner.Code_Health.Diagnostics;
   package E renames Model_Runner.Errors;
   package P renames Model_Runner.Code_Health.Providers;
   use type P.Check_Status;

   Adapter_Version : constant String := "1.0.0";

   function Trim (Text : String) return String is
     (Standard.Ada.Strings.Fixed.Trim (Text, Standard.Ada.Strings.Both));

   function Lower (Text : String) return String is
     (Standard.Ada.Characters.Handling.To_Lower (Text));

   procedure Use_Source
     (Self   : in out Instance;
      Source : Problem_Source) is
   begin
      Self.Source := Source;
   end Use_Source;

   overriding function Version (Self : Instance) return String is
   begin
      pragma Unreferenced (Self);
      return Adapter_Version;
   end Version;

   procedure Normalize_Problems
     (Path     : String;
      Problems : String;
      Snapshot : String;
      Result   : out Model_Runner.Code_Health.Ada.Source_Analysis;
      Status   : out E.Error_Info)
   is
      First      : Natural := Problems'First;
      Recognized : Natural := 0;
   begin
      Result := (others => <>);
      Result.Check.Identifier := To_Unbounded_String ("ada-language-server");
      Result.Check.Required := False;
      Result.Toolchain_Fingerprint.Append ("lsp-adapter:" & Adapter_Version);
      if Problems = "" then
         Result.Check.Status := P.Check_Unavailable;
         Result.Check.Detail := To_Unbounded_String ("the configured language server returned no current result");
         Status := E.Success;
         return;
      elsif Trim (Problems) = "(none)" then
         Result.Check.Status := P.Check_Passed;
         Result.Files_Analyzed.Append (Path);
         Status := E.Success;
         return;
      end if;

      while First <= Problems'Last loop
         declare
            Last : Natural :=
              Standard.Ada.Strings.Fixed.Index
                (Problems (First .. Problems'Last), String'(1 => ASCII.LF));
         begin
            if Last = 0 then
               Last := Problems'Last + 1;
            end if;
            if Last > First then
               declare
                  Line   : constant String := Problems (First .. Last - 1);
                  Colon  : constant Natural := Standard.Ada.Strings.Fixed.Index (Line, ":");
                  Second : constant Natural :=
                    (if Colon = 0 or else Colon = Line'Last then 0
                     else Standard.Ada.Strings.Fixed.Index (Line (Colon + 1 .. Line'Last), ":"));
               begin
                  if Line'Length > 5 and then Lower (Line (Line'First .. Line'First + 4)) = "line "
                    and then Colon > Line'First + 5 and then Second > Colon
                  then
                     declare
                        Number : constant String := Trim (Line (Line'First + 5 .. Colon - 1));
                        Level  : constant String := Lower (Trim (Line (Colon + 1 .. Second - 1)));
                        Words  : constant String := Trim (Line (Second + 1 .. Line'Last));
                        Valid  : constant Boolean :=
                          Number /= "" and then Words /= ""
                          and then (for all Letter of Number => Letter in '0' .. '9')
                          and then Level in "error" | "warning" | "information" | "hint";
                     begin
                        if Valid then
                           declare
                              Finding : constant D.Diagnostic :=
                                (Provider    => To_Unbounded_String ("ada"),
                                 Check_Id    => To_Unbounded_String ("ada-language-server"),
                                 Rule_Id     => To_Unbounded_String ("LSP-DIAGNOSTIC"),
                                 Severity    =>
                                   (if Level = "error" then Code_Health.Error
                                    elsif Level = "warning" then Code_Health.Warning
                                    else Code_Health.Information),
                                 Path        => To_Unbounded_String (Path),
                                 Line        => Natural'Value (Number),
                                 Message     => To_Unbounded_String (Words),
                                 Explanation => To_Unbounded_String
                                   ("The configured Ada language server reported this editor diagnostic"),
                                 Remediation => To_Unbounded_String
                                   ("Correct the reported construct and request current diagnostics"),
                                 Native_Code => To_Unbounded_String (Level),
                                 Snapshot    => To_Unbounded_String (Snapshot),
                                 Provenance  => ["ada-language-server"],
                                 others      => <>);
                           begin
                              D.Append_Validated (Result.Diagnostics, Finding, Status);
                              if not E.Is_Ok (Status) then
                                 return;
                              end if;
                              Recognized := Recognized + 1;
                           end;
                        end if;
                     end;
                  end if;
               end;
            end if;
            First := Last + 1;
         end;
      end loop;

      if Recognized = 0 then
         Result.Check.Status := P.Check_Failed;
         Result.Check.Detail := To_Unbounded_String ("language-server output contained no valid diagnostics");
      else
         Result.Check.Status := P.Check_Findings;
         Result.Files_Analyzed.Append (Path);
      end if;
      Status := E.Success;
   end Normalize_Problems;

   overriding procedure Analyze_Changed_Sources
     (Self          : in out Instance;
      Project_Root  : String;
      Changed       : String_Lists.Vector;
      Configuration : String;
      Snapshot      : String;
      Deadline      : Standard.Ada.Real_Time.Time;
      Cancel        : Model_Runner.Cancellation.Token_Reference;
      Result        : out Model_Runner.Code_Health.Ada.Source_Analysis;
      Status        : out E.Error_Info)
   is
      pragma Unreferenced (Configuration);
      Any_Unavailable : Boolean := False;
      Any_Failed      : Boolean := False;
      Any_Cancelled   : Boolean := False;
      Any_Timed_Out   : Boolean := False;
      use type Standard.Ada.Real_Time.Time;
   begin
      Result := (others => <>);
      Result.Check :=
        (Identifier => To_Unbounded_String ("ada-language-server"),
         Required   => False,
         others     => <>);
      if Self.Source = null then
         Result.Check.Status := P.Check_Unavailable;
         Result.Check.Detail := To_Unbounded_String ("no language-server diagnostic source is configured");
         Result.Toolchain_Fingerprint.Append ("lsp-adapter:" & Adapter_Version);
         Status := E.Success;
         return;
      end if;
      for Path of Changed loop
         declare
            One : Model_Runner.Code_Health.Ada.Source_Analysis;
            Now : constant Standard.Ada.Real_Time.Time := Standard.Ada.Real_Time.Clock;
            Left : constant Duration :=
              (if Deadline = Standard.Ada.Real_Time.Time_Last then 8.0
               elsif Deadline <= Now then 0.0
               else Duration'Min (8.0, Standard.Ada.Real_Time.To_Duration (Deadline - Now)));
         begin
            if Model_Runner.Cancellation.Is_Cancelled (Cancel) then
               Any_Cancelled := True;
               exit;
            elsif Left <= 0.0 then
               Any_Timed_Out := True;
               exit;
            end if;
            Normalize_Problems
              (Path, Self.Source (Project_Root & "/" & Path, Left),
               Snapshot, One, Status);
            if not E.Is_Ok (Status) then
               return;
            end if;
            Any_Unavailable := Any_Unavailable or else One.Check.Status = P.Check_Unavailable;
            Any_Failed := Any_Failed or else One.Check.Status = P.Check_Failed;
            for Index in 1 .. D.Length (One.Diagnostics) loop
               declare
                  Finding : constant D.Diagnostic := D.Element (One.Diagnostics, Index);
               begin
                  D.Append_Validated (Result.Diagnostics, Finding, Status, Project_Root);
                  if not E.Is_Ok (Status) then
                     return;
                  end if;
               end;
            end loop;
            for File of One.Files_Analyzed loop
               Result.Files_Analyzed.Append (File);
            end loop;
         end;
      end loop;
      Result.Check.Status :=
        (if Any_Cancelled then P.Check_Cancelled
         elsif Any_Timed_Out then P.Check_Timed_Out
         elsif Any_Unavailable then P.Check_Unavailable
         elsif Any_Failed then P.Check_Failed
         elsif D.Length (Result.Diagnostics) > 0 then P.Check_Findings
         else P.Check_Passed);
      Result.Toolchain_Fingerprint.Append ("lsp-adapter:" & Adapter_Version);
      Status := E.Success;
   end Analyze_Changed_Sources;

end Model_Runner.Code_Health.Ada_LSP_Adapter;
