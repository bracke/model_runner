--  Video files, on a host this build has no way to open them from.
--
--  Refusing by name is the honest answer rather than a stub that pretends:
--  a video can be given as its frames instead, and the refusal says so.
package body Model_Runner.Platform.Video is

   function Is_Supported return Boolean is (False);

   function Unsupported_Reason return String
   is ("this build has no video decoding for this host");

   procedure Open
     (Item   : in out Reader;
      Path   : String;
      Status : out Model_Runner.Errors.Error_Info) is
   begin
      Close (Item);
      Status := Model_Runner.Errors.Make (Model_Runner.Errors.IO_Video_Unreadable);
      Model_Runner.Errors.Add_Text
        (Status, "path", Path, Model_Runner.Errors.Param_Path);
      Model_Runner.Errors.Add_Text
        (Status, "detail", Unsupported_Reason, Model_Runner.Errors.Param_Text);
   end Open;

   procedure Close (Item : in out Reader) is
   begin
      Item.Ready := False;
   end Close;

   function Is_Open (Item : Reader) return Boolean is (Item.Ready);
   function Frames (Item : Reader) return Positive is (Item.Count);
   function Rate (Item : Reader) return Long_Float is (Item.Per_Second);
   function Width (Item : Reader) return Positive is (Item.Wide);
   function Height (Item : Reader) return Positive is (Item.Tall);

   procedure Next
     (Item    : in out Reader;
      Picture : out Model_Runner.Images.Raster;
      Done    : out Boolean;
      Status  : out Model_Runner.Errors.Error_Info)
   is
      pragma Unreferenced (Item);
   begin
      Picture := (others => <>);
      Done := True;
      Status := Model_Runner.Errors.Make (Model_Runner.Errors.Lifecycle_Model_Not_Ready);
   end Next;

end Model_Runner.Platform.Video;
