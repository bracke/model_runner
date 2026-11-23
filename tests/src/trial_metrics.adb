with Ada.Strings.Fixed;

package body Trial_Metrics is

   function Number_After (Text, Mark : String) return String is
      At_It : Natural;
      First : Natural;
      Last  : Natural;
   begin
      if Mark = "" then
         return "";
      end if;
      At_It := Ada.Strings.Fixed.Index (Text, Mark);
      if At_It = 0 then
         return "";
      end if;
      First := At_It + Mark'Length;
      while First <= Text'Last and then Text (First) = ' ' loop
         First := First + 1;
      end loop;
      Last := First;
      while Last <= Text'Last and then Text (Last) in '0' .. '9' | '.' loop
         Last := Last + 1;
      end loop;
      if Last - First > 18 then
         return "";
      end if;
      return Text (First .. Last - 1);
   end Number_After;

   function Count_After (Text, Mark : String) return Long_Long_Integer is
      Value : constant String := Number_After (Text, Mark);
   begin
      if Value = "" or else (for some C of Value => C not in '0' .. '9') then
         return -1;
      end if;
      return Long_Long_Integer'Value (Value);
   exception
      when Constraint_Error => return -1;
   end Count_After;

   function Seconds_After (Text, Mark : String) return Duration is
      Value : constant String := Number_After (Text, Mark);
   begin
      return (if Value = "" then -1.0 else Duration'Value (Value));
   exception
      when Constraint_Error => return -1.0;
   end Seconds_After;

end Trial_Metrics;
