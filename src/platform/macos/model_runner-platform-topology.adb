with Interfaces.C;
with System;

--  Core count on macOS, from sysctl.
--
--  The kernel answers "hw.physicalcpu" with the number of cores it is willing
--  to schedule on, which is the number wanted here. There is no directory to
--  walk as there is on Linux.
--
--  Not exercised on the machine this was written on. It is written to fail
--  into silence rather than into a wrong number: any refusal from the kernel,
--  any length other than the one asked for, and any value outside the
--  processor count all return zero, and zero means the caller keeps the
--  behaviour it had before this file existed. The worst outcome is the
--  previous default.
package body Model_Runner.Platform.Topology is

   use type Interfaces.C.int;
   use type Interfaces.C.size_t;

   function Sysctl_By_Name
     (Name    : Interfaces.C.char_array;
      Old_P   : System.Address;
      Old_Len : access Interfaces.C.size_t;
      New_P   : System.Address;
      New_Len : Interfaces.C.size_t) return Interfaces.C.int
     with Import, Convention => C, External_Name => "sysctlbyname";

   ---------------------
   -- Physical_Cores --
   ---------------------

   function Physical_Cores (Processors : Positive) return Natural is
      Name   : constant Interfaces.C.char_array :=
        Interfaces.C.To_C ("hw.physicalcpu");
      Value  : aliased Interfaces.C.int := 0;
      Length : aliased Interfaces.C.size_t := Value'Size / 8;
      Result : Interfaces.C.int;
   begin
      Result :=
        Sysctl_By_Name
          (Name    => Name,
           Old_P   => Value'Address,
           Old_Len => Length'Access,
           New_P   => System.Null_Address,
           New_Len => 0);

      if Result /= 0 or else Length /= Value'Size / 8 then
         return 0;
      end if;

      if Integer (Value) in 1 .. Processors then
         return Natural (Value);
      end if;

      return 0;
   exception
      when others =>
         return 0;
   end Physical_Cores;

end Model_Runner.Platform.Topology;
