with Interfaces;

--  Turn a compiled shader into an Ada constant.
--
--  A shader is source in another language, which the repository carries, and
--  a compiled shader is a run of thirty-two bit words, which it does not: a
--  binary in a source tree is a thing nobody can read or review. So the
--  words are written out as Ada and committed beside the source they came
--  from, and the engine hands them to the device without opening a file --
--  which it could not do anyway, being one of the units that may not reach
--  the filesystem.
--
--  Compiling is not done here. It needs a shader compiler, which is not a
--  build dependency of this project and should not become one for the sake
--  of a file that changes twice a year. Whoever changes the shader runs the
--  compiler and passes its output to this, and the check in Checks notices
--  when the source has moved and the words have not.
--
--  Task safety: one call at a time; it writes a file.
package Shader_Generation is

   --  Write the Ada constant for one compiled shader.
   --
   --  @param Root Repository root.
   --  @param Source Path of the shader source, for its digest.
   --  @param Compiled Path of the compiled words.
   --  @param Written True when the package was written.
   procedure Write_Shader
     (Root     : String;
      Source   : String;
      Compiled : String;
      Written  : out Boolean);

   --  A digest of a shader source, as the generated package records it.
   --
   --  Written into the generated file so that a source which has changed
   --  since it was compiled can be told from one which has not. It
   --  identifies a text; it does not verify one.
   --
   --  @param Path Shader source to read.
   --  @param Found True when the file could be read.
   --  @return The digest, or zero when it could not be read.
   function Source_Digest
     (Path : String; Found : out Boolean) return Interfaces.Unsigned_64;

end Shader_Generation;
