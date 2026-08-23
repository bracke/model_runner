with Model_Runner.Conversation;
with Model_Runner.Errors;
with Model_Runner.Templates;

package body Template_Registry is

   package Conv renames Model_Runner.Conversation;
   package E renames Model_Runner.Errors;
   package Tmpl renames Model_Runner.Templates;

   --  A name for every variable slot the table holds, and one more, so that
   --  the row about the name table is exercised rather than described.
   function Too_Many_Names return String is
      Piece : constant String := "{% set n";
      Room  : String (1 .. (Tmpl.Max_Variables + 4) * 24);
      Used  : Natural := 0;

      procedure Add (Text : String) is
      begin
         Room (Used + 1 .. Used + Text'Length) := Text;
         Used := Used + Text'Length;
      end Add;
   begin
      for Index in 1 .. Tmpl.Max_Variables + 4 loop
         Add (Piece);
         declare
            Number : constant String := Integer'Image (Index);
         begin
            Add (Number (Number'First + 1 .. Number'Last));
         end;
         Add (" = 'x' %}");
      end loop;
      Add ("{{ n1 }}");
      return Room (1 .. Used);
   end Too_Many_Names;

   Held : constant array (1 .. 38) of Example :=
     [(new String'("Literal text"),
       new String'("hello"),
       Works),

      (new String'("`{{ terms }}` joined by `+`"),
       new String'("{{ 'a' + 'b' }}"),
       Works),

      (new String'("`{% for message in LIST %}`"),
       new String'("{% for message in messages %}x{% endfor %}"),
       Works),

      (new String'("`{% for name in range(a, b, c) %}`"),
       new String'("{% for i in range(2, -1, -1) %}{{ i }}{% endfor %}"),
       Works),

      (new String'("`<`, `<=`, `>`, `>=`"),
       new String'("{% if 2 > 1 and 1 < 2 and 2 >= 2 and 1 <= 1 %}y"
                   & "{% endif %}"),
       Works),

      (new String'("A bare operand as a condition"),
       new String'("{% if 'a' %}y{% endif %}{% if never %}n{% endif %}"),
       Works),

      (new String'("`namespace()` and its fields"),
       new String'("{% set ns = namespace(a=true) %}"
                   & "{% if ns.a %}y{% endif %}"),
       Works),

      (new String'("`-` between terms"),
       new String'("{{ messages|length - 1 }}"
                   & "{% for message in messages %}"
                   & "{{ messages[loop.index0 + 1].role }}{% endfor %}"),
       Works),

      (new String'("`'x' in TEXT`, `'x' not in TEXT`"),
       new String'("{% if 'b' in 'abc' and 'z' not in 'abc' %}y{% endif %}"),
       Works),

      (new String'("The line a block tag stands on"),
       new String'("a" & Character'Val (10) & "  {% if true %}b{% endif %}"
                   & Character'Val (10) & "c"),
       Works),

      (new String'("Brackets round part of a sum"),
       new String'("{% set n = (messages|length - 1) - 0 %}{{ n }}"
                   & "{{ 10 - (3 - 1) }}"),
       Works),

      (new String'("`TEXT[a:b]`, `TEXT[a:]`, `TEXT[:b]`"),
       new String'("{{ messages[1].content[:1] }}"
                   & "{{ messages[1].content[1:] }}"
                   & "{{ messages[1].content[-1:] }}"),
       Works),

      (new String'("`\| first`, `\| last`"),
       new String'("{{ 'a-b'.split('-')|first }}{{ 'a-b'.split('-')|last }}"),
       Works),

      (new String'("`.strip(S)`, `.lstrip(S)`, `.rstrip(S)`, "
                   & "`.split(S)[0]`, `.split(S)[-1]`"),
       new String'("{% set t = 'a|b|c' %}"
                   & "{{ t.split('|')[0] }}{{ t.split('|')[-1] }}"
                   & "{{ t.strip('a') }}{{ t.lstrip('a') }}"
                   & "{{ t.rstrip('c') }}"),
       Works),

      (new String'("Date formatting"),
       new String'("{{ strftime_now('%Y') }}"),
       Refused_At_Render),

      (new String'("`{% for name in tools %}`"),
       new String'("{% for tool in tools %}{{ tool | tojson }}{% endfor %}"),
       Works),

      (new String'("`{% for tool_call in message.tool_calls %}`"),
       new String'("{% for message in messages %}"
                   & "{% for tool_call in message.tool_calls %}"
                   & "{{ tool_call.name }}{% endfor %}{% endfor %}"),
       Works),

      (new String'("`message.tool_calls`, `tool_call.name`, "
                   & "`tool_call.arguments`"),
       new String'("{% for message in messages %}"
                   & "{% if message.tool_calls %}"
                   & "{% for tool_call in message.tool_calls %}"
                   & "{{ tool_call.name }}{{ tool_call.arguments }}"
                   & "{% endfor %}{% endif %}{% endfor %}"),
       Works),

      (new String'("`\| tojson`"),
       new String'("{{ 'text' | tojson }}"),
       Works),

      (new String'("`{% if %}` / `{% elif %}` / `{% else %}` / `{% endif %}`"),
       new String'("{% if add_generation_prompt %}a{% elif true %}b"
                   & "{% else %}c{% endif %}"),
       Works),

      (new String'("`==`, `!=`, `and`, `or`, `not`"),
       new String'("{% if 'a' == 'a' and not 'a' != 'a' or false %}y"
                   & "{% endif %}"),
       Works),

      (new String'("`bos_token`, `eos_token`, `add_generation_prompt`"),
       new String'("{{ bos_token }}{{ eos_token }}"
                   & "{% if add_generation_prompt %}g{% endif %}"),
       Works),

      (new String'("`message['role']`, `message['content']`, dotted forms"),
       new String'("{% for message in messages %}{{ message['role'] }}"
                   & "{{ message.content }}{% endfor %}"),
       Works),

      (new String'("`messages[0]['role']` and its like"),
       new String'("{{ messages[0]['role'] }}{{ messages[0]['content'] }}"),
       Works),

      (new String'("`{# comments #}`"),
       new String'("{# nothing to see #}text"),
       Works),

      (new String'("`{% set %}`"),
       new String'("{% set a = 'x' %}{% set b = a %}{% set c = none %}"
                   & "{% set rest = messages[1:] %}{{ a }}{{ b }}"
                   & "{% for message in rest %}m{% endfor %}"),
       Works),

      (new String'("`true`, `false`, `none`, decimal numbers"),
       new String'("{% if true and not false %}{{ 12 }}{% endif %}"
                   & "{% set n = none %}"),
       Works),

      (new String'("`is defined`, `is none`, `is true`, `is false`, "
                   & "`is string`, `is not ...`"),
       new String'("{% if not tools is defined %}{% set tools = none %}"
                   & "{% endif %}{% if tools is none %}a{% endif %}"
                   & "{% if bos_token is not none %}b{% endif %}"
                   & "{% if true is true and false is false %}c{% endif %}"
                   & "{% if bos_token is string %}d{% endif %}"),
       Works),

      (new String'("`'field' in message`"),
       new String'("{% for message in messages %}"
                   & "{% if 'role' in message %}y{% endif %}"
                   & "{% if 'tool_calls' in message %}n{% endif %}"
                   & "{% endfor %}"),
       Works),

      (new String'("Parenthesised conditions"),
       new String'("{% for message in messages %}"
                   & "{% if not (message.role == 'tool'"
                   & " or 'tool_calls' in message) %}y{% endif %}"
                   & "{% endfor %}"),
       Works),

      (new String'("`\| trim`, `\| length`"),
       new String'("{% for message in messages %}"
                   & "{{ message.content | trim }}{% endfor %}"
                   & "{% if messages | length != 0 %}n{% endif %}"),
       Works),

      (new String'("`loop.first`, `loop.last`, `loop.index`, `loop.index0`"),
       new String'("{% for message in messages %}"
                   & "{% if loop.first %}f{% endif %}"
                   & "{% if loop.last %}l{% endif %}"
                   & "{{ loop.index }}{{ loop.index0 }}{% endfor %}"),
       Works),

      (new String'("`{%- -%}` and `{{- -}}` whitespace control"),
       new String'("  {%- if true -%}  a  {%- endif -%}  {{- 'b' -}}  "),
       Works),

      (new String'("`macro`, `include`, `import`"),
       new String'("{% macro m() %}{% endmacro %}"),
       Refused_At_Compile),

      (new String'("Other filters"),
       new String'("{{ bos_token | upper }}"),
       Refused_At_Render),

      (new String'("Function calls, `strftime_now`, "
                   & "`raise_exception`, arithmetic, indexing by anything "
                   & "but a number"),
       new String'("{{ raise_exception('no') }}"),
       Refused_At_Render),

      (new String'("Reading a name the template never assigned"),
       new String'("{{ never_assigned }}"),
       Refused_At_Render),

      (new String'("More than 32 names, or more variable text than the pool "
                   & "holds"),
       new String'(Too_Many_Names),
       Refused_At_Render)];

   -----------
   -- Count --
   -----------

   function Count return Natural is (Held'Length);

   ----------
   -- Item --
   ----------

   function Item (Index : Positive) return Example is (Held (Index));

   ---------
   -- Run --
   ---------

   function Run (Source : String; Detail : out Text_Access) return Outcome is
      Compiled : Tmpl.Compiled;
      Messages : Conv.History;
      Status   : E.Error_Info;
      Room     : String (1 .. 8192);
      Last     : Natural;
      Result   : Outcome;
   begin
      Detail := null;

      Tmpl.Compile (Compiled, Source, Status => Status);
      if E.Is_Error (Status) then
         Detail := new String'(E.Error_Code'Image (Status.Code));
         Tmpl.Close (Compiled);
         return Refused_At_Compile;
      end if;

      --  Two messages, the first of them a system message, because several
      --  of the rows are about what a template does with one.
      Conv.Open (Messages, Status => Status);
      Conv.Append (Messages, Conv.System_Role, " be brief ", Status);
      Conv.Append (Messages, Conv.User_Role, "hi", Status);

      Tmpl.Render
        (Compiled, Messages, "<s>", "</s>", True, Room, Last, Status);
      if E.Is_Error (Status) then
         Detail := new String'(E.Error_Code'Image (Status.Code));
         Result := Refused_At_Render;
      else
         Result := Works;
      end if;

      Conv.Close (Messages);
      Tmpl.Close (Compiled);
      return Result;
   end Run;

end Template_Registry;
