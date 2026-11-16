with Ada.Characters.Handling;
with Ada.Exceptions;

with Model_Runner.Framework.Templates;
with Model_Runner.UTF8;

package body Model_Runner.Code_Health.Providers is

   use Ada.Strings.Unbounded;
   use type Ada.Real_Time.Time;

   package D renames Model_Runner.Code_Health.Diagnostics;
   package E renames Model_Runner.Errors;

   Maximum_Result_Items : constant := 10_000;
   Maximum_Field_Bytes  : constant := 64 * 1024;

   procedure Refuse
     (Status : out E.Error_Info;
      Name   : String;
      Value  : String;
      Detail : String) is
   begin
      Status := E.Make (E.Framework_Schema_Violation);
      E.Add_Text (Status, "name", Name);
      E.Add_Text (Status, "value", Value);
      E.Add_Text (Status, "detail", Detail);
   end Refuse;

   function Valid_Identifier (Value : String) return Boolean is
   begin
      return Value'Length > 0
        and then Value (Value'First) in 'a' .. 'z'
        and then (for all Letter of Value =>
                    Letter in 'a' .. 'z' | '0' .. '9' | '-' | '_');
   end Valid_Identifier;

   function Valid_Version (Value : String) return Boolean is
   begin
      return Value'Length > 0
        and then (for all Letter of Value =>
                    Ada.Characters.Handling.Is_Alphanumeric (Letter)
                    or else Letter in '.' | '-' | '_' | '+');
   end Valid_Version;

   function Valid_Check_Identifier (Value : String) return Boolean is
     (Value'Length in 1 .. 200
      and then Value (Value'First) in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9'
      and then (for all Letter of Value =>
                  Letter in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' | ':' | '/'));

   function Valid_Text (Value : String) return Boolean is
     (Value'Length <= Maximum_Field_Bytes and then Model_Runner.UTF8.Is_Valid (Value));

   procedure Validate_Result
     (Item              : Analysis_Result;
      Status            : out E.Error_Info;
      Expected_Provider : String := "";
      Expected_Version  : String := "";
      Expected_Snapshot : String := "";
      Project_Root      : String := "")
   is
      Provider_Id : constant String := To_String (Item.Provider_Id);
      Release     : constant String := To_String (Item.Provider_Version);
      Cancelled   : Boolean := False;
      Timed_Out   : Boolean := False;

      procedure Reject (Name, Detail : String) is
      begin
         Refuse (Status, Name, "", Detail);
      end Reject;
   begin
      if not Valid_Identifier (Provider_Id) then
         Reject ("provider", "analysis result has an invalid provider identifier");
         return;
      elsif Expected_Provider /= "" and then Provider_Id /= Expected_Provider then
         Reject ("provider", "analysis result names a different provider");
         return;
      elsif not Valid_Version (Release) then
         Reject ("provider_version", "analysis result has an invalid provider version");
         return;
      elsif Expected_Version /= "" and then Release /= Expected_Version then
         Reject ("provider_version", "analysis result names a different provider version");
         return;
      elsif Item.Checks.Is_Empty then
         Reject ("checks", "analysis result contains no check outcome");
         return;
      elsif Natural (Item.Checks.Length) > Maximum_Result_Items
        or else D.Length (Item.Diagnostics) > Maximum_Result_Items
        or else Natural (Item.Files_Analyzed.Length) > Maximum_Result_Items
        or else Natural (Item.Evidence.Length) > Maximum_Result_Items
      then
         Reject ("result", "analysis result exceeds the retained item limit");
         return;
      elsif Item.Duration < 0.0 then
         Reject ("duration", "analysis result has a negative duration");
         return;
      end if;

      for Text of String_Lists.Vector'
        ([To_String (Item.Input_Fingerprint), To_String (Item.Configuration_Fingerprint),
          To_String (Item.Toolchain_Fingerprint), To_String (Item.Environment_Fingerprint),
          To_String (Item.Resource_Summary)])
      loop
         if not Valid_Text (Text) then
            Reject ("result", "analysis result contains invalid or oversized text");
            return;
         end if;
      end loop;
      if Expected_Snapshot /= ""
        and then To_String (Item.Input_Fingerprint) /= Expected_Snapshot
      then
         Reject ("input", "analysis result belongs to another source snapshot");
         return;
      end if;

      for Index in 1 .. Natural (Item.Checks.Length) loop
         declare
            Check : constant Check_Result := Item.Checks.Element (Index);
            Id    : constant String := To_String (Check.Identifier);
         begin
            if not Valid_Check_Identifier (Id) then
               Reject ("check", "analysis result contains an invalid check identifier");
               return;
            elsif Check.Status = Check_Not_Run then
               Reject ("check", "completed analysis contains a check that was not run");
               return;
            elsif not Valid_Text (To_String (Check.Detail))
              or else not Valid_Text (To_String (Check.Evidence))
            then
               Reject ("check", "analysis result contains invalid or oversized check text");
               return;
            end if;
            for Earlier in 1 .. Index - 1 loop
               if To_String (Item.Checks.Element (Earlier).Identifier) = Id then
                  Reject ("check", "analysis result contains a duplicate check identifier");
                  return;
               end if;
            end loop;
            Cancelled := Cancelled or else Check.Status = Check_Cancelled;
            Timed_Out := Timed_Out or else Check.Status = Check_Timed_Out;
         end;
      end loop;
      if Item.Cancelled /= Cancelled then
         Reject ("cancelled", "analysis cancellation flag disagrees with its checks");
         return;
      elsif Item.Timed_Out /= Timed_Out then
         Reject ("timed_out", "analysis timeout flag disagrees with its checks");
         return;
      end if;

      for Path of Item.Files_Analyzed loop
         if not Valid_Text (Path)
           or else not Model_Runner.Framework.Templates.Is_Project_Path (Path)
         then
            Reject ("file", "analysis result contains a path outside the project");
            return;
         end if;
      end loop;
      for Evidence of Item.Evidence loop
         if not Valid_Text (Evidence) then
            Reject ("evidence", "analysis result contains invalid or oversized evidence text");
            return;
         end if;
      end loop;
      for Index in 1 .. D.Length (Item.Diagnostics) loop
         declare
            Finding : D.Diagnostic := D.Element (Item.Diagnostics, Index);
            Checked : E.Error_Info;
         begin
            D.Prepare (Finding, Checked, Project_Root);
            if E.Is_Error (Checked) then
               Reject ("diagnostic", "analysis result contains malformed diagnostic data");
               return;
            elsif Expected_Snapshot /= ""
              and then To_String (Finding.Snapshot) /= Expected_Snapshot
            then
               Reject ("diagnostic", "analysis result contains a diagnostic from another snapshot");
               return;
            end if;
         end;
      end loop;
      Status := E.Success;
   end Validate_Result;

   procedure Analyze_Safely
     (Self    : in out Provider'Class;
      Request : Analysis_Request;
      Result  : out Analysis_Result;
      Status  : out E.Error_Info)
   is
      Provider_Id : Unbounded_String;
      Release     : Unbounded_String;

      procedure Failed (Kind : Check_Status; Detail : String) is
      begin
         Result := (others => <>);
         Result.Provider_Id := Provider_Id;
         Result.Provider_Version := Release;
         Result.Input_Fingerprint := Request.Change_Id;
         Result.Configuration_Fingerprint := Request.Configuration;
         Result.Cancelled := Kind = Check_Cancelled;
         Result.Timed_Out := Kind = Check_Timed_Out;
         Result.Checks.Append
           (Check_Result'
              (Identifier => To_Unbounded_String ("provider-operation"),
               Status     => Kind,
               Required   => True,
               Detail     => To_Unbounded_String (Detail),
               Evidence   => Null_Unbounded_String));
      end Failed;
   begin
      Result := (others => <>);
      Provider_Id := To_Unbounded_String (Identifier (Self));
      Release := To_Unbounded_String (Version (Self));
      if Model_Runner.Cancellation.Is_Cancelled (Request.Cancel) then
         Failed (Check_Cancelled, "analysis was cancelled before the provider started");
         Status := E.Success;
         return;
      elsif Request.Deadline /= Ada.Real_Time.Time_Last
        and then Request.Deadline <= Ada.Real_Time.Clock
      then
         Failed (Check_Timed_Out, "analysis deadline expired before the provider started");
         Status := E.Success;
         return;
      end if;

      Analyze (Self, Request, Result, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Validate_Result
        (Result, Status, To_String (Provider_Id), To_String (Release),
         To_String (Request.Change_Id), To_String (Request.Project_Root));
      if E.Is_Error (Status) then
         Failed (Check_Failed, "provider returned structurally invalid analysis data");
      end if;
   exception
      when Failure : others =>
         Failed (Check_Failed, "provider failed while analyzing the requested snapshot");
         Status := E.Make (E.Internal_Unexpected_Exception);
         E.Add_Text (Status, "name", To_String (Provider_Id));
         E.Add_Text (Status, "detail", Ada.Exceptions.Exception_Name (Failure));
   end Analyze_Safely;

   procedure Probe_Cache_Safely
     (Self    : in out Cache_Aware_Provider'Class;
      Request : Analysis_Request;
      Result  : out Cache_Probe;
      Status  : out E.Error_Info) is
   begin
      Result := (others => <>);
      if Model_Runner.Cancellation.Is_Cancelled (Request.Cancel) then
         Result.Detail := To_Unbounded_String ("cache probe was cancelled");
         Status := E.Success;
         return;
      elsif Request.Deadline /= Ada.Real_Time.Time_Last
        and then Request.Deadline <= Ada.Real_Time.Clock
      then
         Result.Detail := To_Unbounded_String ("cache probe deadline expired");
         Status := E.Success;
         return;
      end if;
      Probe_Cache (Self, Request, Result, Status);
      if E.Is_Error (Status) then
         Result := (others => <>);
         return;
      elsif Result.Reusable
        and then (Length (Result.Configuration_Fingerprint) = 0
                  or else Length (Result.Toolchain_Fingerprint) = 0
                  or else Length (Result.Environment_Fingerprint) = 0)
      then
         Result := (others => <>);
         Refuse
           (Status, "cache_probe", "",
            "provider marked an incomplete cache fingerprint reusable");
      else
         Status := E.Success;
      end if;
   exception
      when Failure : others =>
         Result := (others => <>);
         Status := E.Make (E.Internal_Unexpected_Exception);
         E.Add_Text (Status, "name", "cache probe");
         E.Add_Text (Status, "detail", Ada.Exceptions.Exception_Name (Failure));
   end Probe_Cache_Safely;

   procedure Register
     (Into   : in out Registry;
      Item   : not null Provider_Reference;
      Status : out E.Error_Info)
   is
      Id : constant String := Identifier (Item.all);
   begin
      if not Valid_Identifier (Id) then
         Refuse (Status, "provider", Id, "invalid provider identifier");
         return;
      elsif not Valid_Version (Version (Item.all)) then
         Refuse (Status, "provider", Id, "invalid provider version");
         return;
      elsif Contains (Into, Id) then
         Refuse (Status, "provider", Id, "duplicate provider identifier");
         return;
      end if;

      --  Keep the registry sorted, making selection independent of startup
      --  registration order.
      for Index in 1 .. Natural (Into.Items.Length) loop
         if Id < Identifier (Into.Items.Element (Index).all) then
            Into.Items.Insert (Index, Item);
            Status := E.Success;
            return;
         end if;
      end loop;
      Into.Items.Append (Item);
      Status := E.Success;
   end Register;

   function Length (From : Registry) return Natural is
     (Natural (From.Items.Length));

   function Length (From : Provider_List) return Natural is
     (Natural (From.Items.Length));

   function Element
     (From  : Provider_List;
      Index : Positive) return Provider_Reference is
     (From.Items.Element (Index));

   function Contains
     (Within     : Registry;
      Identifier : String) return Boolean is
     (Find (Within, Identifier) /= null);

   function Find
     (Within     : Registry;
      Identifier : String) return Provider_Reference is
   begin
      for Item of Within.Items loop
         if Providers.Identifier (Item.all) = Identifier then
            return Item;
         end if;
      end loop;
      return null;
   end Find;

   function Select_Providers
     (From  : Registry;
      Path  : String;
      Level : Check_Level) return Provider_List
   is
      Result : Provider_List;
   begin
      for Item of From.Items loop
         if Supports (Item.all, Path, Level) then
            Result.Items.Append (Item);
         end if;
      end loop;
      return Result;
   end Select_Providers;

end Model_Runner.Code_Health.Providers;
