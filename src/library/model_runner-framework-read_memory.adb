with Ada.Calendar;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;

with Hostkit.Metadata;

package body Model_Runner.Framework.Read_Memory is

   use Ada.Strings.Unbounded;

   --  What each file gave, by kind and path, with its stamp.
   package Remembered_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => String, Hash => Ada.Strings.Hash, Equivalent_Keys => "=");

   --  The most held before all are let go.
   Remembered_Most : constant := 50_000;

   protected Reads is
      procedure Get (Key, Stamp : String; Value : out Unbounded_String; Found : out Boolean);
      procedure Put (Key, Stamp, Value : String);
   private
      Held : Remembered_Maps.Map;
   end Reads;

   protected body Reads is
      procedure Get (Key, Stamp : String; Value : out Unbounded_String; Found : out Boolean) is
         Position : constant Remembered_Maps.Cursor := Held.Find (Key);
      begin
         Found := False;
         Value := Null_Unbounded_String;
         if Remembered_Maps.Has_Element (Position) then
            declare
               Kept : constant String := Remembered_Maps.Element (Position);
               Cut  : constant Natural := Ada.Strings.Fixed.Index (Kept, [1 => ASCII.NUL]);
            begin
               if Cut > 0 and then Kept (Kept'First .. Cut - 1) = Stamp then
                  Value := To_Unbounded_String (Kept (Cut + 1 .. Kept'Last));
                  Found := True;
               end if;
            end;
         end if;
      end Get;

      procedure Put (Key, Stamp, Value : String) is
      begin
         if Natural (Held.Length) >= Remembered_Most then
            Held.Clear;
         end if;
         Held.Include (Key, Stamp & ASCII.NUL & Value);
      end Put;
   end Reads;

   --  What reading a file gives, from memory where its stamp says it is
   --  as it was, else read and remembered. Its stamp is taken before it is
   --  read, so a change while it is read is a stamp that differs next time.
   --  What could not be read -- a value starting with "!" -- is not held.
   --  A file's stamp, one look at it: its size and its modification and
   --  change times to the nanosecond; "" where the host gives no such
   --  times, or where they are within two seconds of now -- two writes of
   --  one size in one kernel tick share them -- and what it holds must be
   --  read again.
   function Trusted_Stamp (Full : String) return String is
      use type Hostkit.Metadata.Identity_Field;
      Now : constant Long_Long_Integer :=
        Long_Long_Integer (Ada.Calendar."-" (Ada.Calendar.Clock, Ada.Calendar.Time_Of (1970, 1, 1)));
      Was : constant Hostkit.Metadata.Entry_Revision := Hostkit.Metadata.Entry_Revision_Of (Full);
      function Image (Field : Hostkit.Metadata.Identity_Field) return String
      is (Ada.Strings.Fixed.Trim (Hostkit.Metadata.Identity_Field'Image (Field), Ada.Strings.Both));
   begin
      if not Was.Available
        or else Was.Changed_Seconds = 0
        or else Now - Long_Long_Integer (Hostkit.Metadata.Identity_Field'Max
                                           (Was.Modified_Seconds, Was.Changed_Seconds)) < 2
      then
         return "";
      end if;
      return Image (Was.Size) & ":" & Image (Was.Modified_Seconds) & "." & Image (Was.Modified_Nanoseconds)
        & ":" & Image (Was.Changed_Seconds) & "." & Image (Was.Changed_Nanoseconds);
   exception
      when others =>
         return "";
   end Trusted_Stamp;

   function Remembered
     (Kind, Full : String;
      Work       : not null access function return String) return String
   is
      Stamp : constant String := Trusted_Stamp (Full);
      Value : Unbounded_String;
      Found : Boolean := False;
   begin
      if Stamp /= "" then
         Reads.Get (Kind & ":" & Full, Stamp, Value, Found);
         if Found then
            return To_String (Value);
         end if;
      end if;
      declare
         Fresh : constant String := Work.all;
      begin
         if Stamp /= "" and then (Fresh'Length = 0 or else Fresh (Fresh'First) /= '!')
         then
            Reads.Put (Kind & ":" & Full, Stamp, Fresh);
         end if;
         return Fresh;
      end;
   end Remembered;

end Model_Runner.Framework.Read_Memory;
