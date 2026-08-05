with Ada.Directories;
with Ada.Text_IO;

with Model_Runner.Errors;
with Model_Runner.Text;

package body Docs_Generation is

   use type Model_Runner.Errors.Error_Code;
   use type Model_Runner.Errors.Error_Domain;

   package E renames Model_Runner.Errors;
   package T renames Model_Runner.Text;

   Relative : constant String := "docs/error-codes.md";

   --  Build the whole reference in memory so that writing it and comparing it
   --  use exactly the same bytes.
   function Rendered return String is
      Buffer : String (1 .. 200_000);
      Filled : Natural := 0;

      procedure Put (Item : String) is
      begin
         if Filled + Item'Length <= Buffer'Length then
            Buffer (Filled + 1 .. Filled + Item'Length) := Item;
            Filled := Filled + Item'Length;
         end if;
      end Put;

      procedure Line (Item : String) is
      begin
         Put (Item);
         Put ([1 => ASCII.LF]);
      end Line;

      Current : E.Error_Domain := E.Domain_None;
   begin
      Line ("# Error-code reference");
      Line ("");
      Line ("Generated from `Model_Runner.Errors.Error_Code` by `tests docs`.");
      Line ("Do not edit by hand.");
      Line ("");
      Line ("A code is stable: the ordinal is the literal's position within its");
      Line ("domain group, so codes are appended, never reordered or removed.");
      Line ("");

      for Code in E.Error_Code loop
         if Code /= E.No_Error then
            if E.Domain (Code) /= Current then
               Current := E.Domain (Code);
               Line ("");
               Line ("## " & E.Domain_Token (Current));
               Line ("");
               Line ("| Code | Message key | Recovery | Exit |");
               Line ("| --- | --- | --- | --- |");
            end if;

            Line
              ("| `" & E.Diagnostic_Code (Code) & "` | `"
               & E.Message_Key (Code) & "` | "
               & T.To_Lower
                   (E.Recovery_Class'Image (E.Recovery (Code)))
               & " | "
               & T.Image
                   (Long_Long_Integer
                      (E.Exit_Status (E.Make (Code)))) & " |");
         end if;
      end loop;

      return Buffer (1 .. Filled);
   end Rendered;

   -----------------------------
   -- Write_Error_Reference --
   -----------------------------

   procedure Write_Error_Reference (Root : String; Written : out Boolean) is
      Path   : constant String := Root & "/" & Relative;
      Handle : Ada.Text_IO.File_Type;
   begin
      Written := False;

      if not Ada.Directories.Exists (Root & "/docs") then
         Ada.Directories.Create_Directory (Root & "/docs");
      end if;

      Ada.Text_IO.Create (Handle, Ada.Text_IO.Out_File, Path);
      Ada.Text_IO.Put (Handle, Rendered);
      Ada.Text_IO.Close (Handle);
      Written := True;
   exception
      when others =>
         Written := False;
   end Write_Error_Reference;

   ----------------------------------
   -- Error_Reference_Is_Current --
   ----------------------------------

   function Error_Reference_Is_Current (Root : String) return Boolean is
      Path     : constant String := Root & "/" & Relative;
      Expected : constant String := Rendered;
      Handle   : Ada.Text_IO.File_Type;
      Buffer   : String (1 .. Expected'Length + 16);
      Filled   : Natural := 0;
   begin
      if not Ada.Directories.Exists (Path) then
         return False;
      end if;

      Ada.Text_IO.Open (Handle, Ada.Text_IO.In_File, Path);
      while not Ada.Text_IO.End_Of_File (Handle) loop
         declare
            Item : constant String := Ada.Text_IO.Get_Line (Handle);
         begin
            exit when Filled + Item'Length + 1 > Buffer'Length;
            Buffer (Filled + 1 .. Filled + Item'Length) := Item;
            Filled := Filled + Item'Length + 1;
            Buffer (Filled) := ASCII.LF;
         end;
      end loop;
      Ada.Text_IO.Close (Handle);

      return Buffer (1 .. Filled) = Expected;
   exception
      when others =>
         return False;
   end Error_Reference_Is_Current;

end Docs_Generation;
