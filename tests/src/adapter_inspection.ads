with Interfaces;

--  Compare bounded GGUF headers without representing missing payload as verified model data.
package Adapter_Inspection is

   --  @param Base Original GGUF file or bounded header prefix.
   --  @param Adapted Adapted GGUF file or bounded header prefix.
   --  @param Adapter Adapter GGUF file or bounded header prefix.
   --  @param Output_Path JSON inspection report; tensor payload is never declared verified.
   --  @param Base_Bytes Advertised complete size, or zero to use the local file's size.
   --  @param Adapted_Bytes Advertised complete size, or zero to use the local file's size.
   --  @param Adapter_Bytes Advertised complete size, or zero to use the local file's size.
   --  @param Clean Whether all inspected descriptors are compatible.
   procedure Run
     (Base, Adapted, Adapter, Output_Path : String;
      Base_Bytes, Adapted_Bytes, Adapter_Bytes : Interfaces.Unsigned_64;
      Clean : out Boolean);

end Adapter_Inspection;
