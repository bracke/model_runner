with Ada.Finalization;
with Ada.Streams;

--  Room for a buffer held on the heap rather than in a frame, and let go
--  when the object holding it ends, however its scope ends.
--
--  A task's stack is two megabytes unless it says otherwise, and the main
--  task's eight: a megabyte read buffer in a frame -- or one as long as a
--  file -- leaves a task little, and one of four runs it out. Declared
--  where the buffer was, with the buffer renamed from it:
--
--     Room   : Heap_Buffers.Bytes (1024 * 1024);
--     Buffer : Stream_Element_Array renames Room.Data.all;
package Model_Runner.Heap_Buffers is

   type Byte_Access is access Ada.Streams.Stream_Element_Array;
   type Text_Access is access String;

   --  Length bytes, 1 .. Length.
   type Bytes (Length : Ada.Streams.Stream_Element_Offset) is
     new Ada.Finalization.Limited_Controlled with record
      Data : Byte_Access;
   end record;

   overriding procedure Initialize (Item : in out Bytes);
   overriding procedure Finalize (Item : in out Bytes);

   --  Length characters, 1 .. Length.
   type Text (Length : Natural) is new Ada.Finalization.Limited_Controlled with record
      Data : Text_Access;
   end record;

   overriding procedure Initialize (Item : in out Text);
   overriding procedure Finalize (Item : in out Text);

   --  Any one object so held: a record of fixed room -- a grammar, a
   --  conversation, a listing of hundreds of files -- that made a frame of
   --  hundreds of kilobytes where it was declared.
   --
   --     package Grammar_Rooms is new Heap_Buffers.Holders (Grammar.Compiled);
   --     Rules_Room : Grammar_Rooms.Holder;
   --     Rules      : Grammar.Compiled renames Rules_Room.Data.all;
   generic
      type Element is limited private;
   package Holders is
      type Element_Access is access Element;

      type Holder is new Ada.Finalization.Limited_Controlled with record
         Data : Element_Access;
      end record;

      overriding procedure Initialize (Item : in out Holder);
      overriding procedure Finalize (Item : in out Holder);
   end Holders;

end Model_Runner.Heap_Buffers;
