package body Raise_Interrupt is

   -----------------
   -- Can_Request --
   -----------------

   --  A console control event is the only thing the engine's handler listens
   --  for, and a process may send one only to its entire console group. In a
   --  test runner that group contains the shell that started it, which is
   --  left holding an interrupt it did not ask for; doing so wedged the job
   --  rather than failing it. Windows offers no per-process form.
   --
   --  So this says no, and the test asserts what can be asserted here -- that
   --  the handler installs and can be removed -- rather than pretending to
   --  exercise delivery or quietly skipping.
   function Can_Request return Boolean is (False);

   -------------
   -- Request --
   -------------

   function Request return Boolean is (False);

end Raise_Interrupt;
