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

   Held : constant array (1 .. 53) of Example :=
     [(new String'("Literal text"),
       new String'("hello"),
       Works),

      (new String'("`{{ terms }}` joined by `+` or `~`"),
       new String'("{{ 'a' + 'b' }}{{ 'a' ~ 1 + 2 }}"),
       Works),

      (new String'("`{% for name in LIST %}`, "
                   & "`{% for key, value in MAPPING %}`, `LIST[::-1]`"),
       new String'("{% for message in messages %}x{% endfor %}"
                   & "{% for m in messages[::-1] %}{{ m.role }}{% endfor %}"
                   & "{% set o = 'a' %}{% for m in messages %}"
                   & "{% set o = 'b' %}{% for n in messages %}"
                   & "{{ loop.index }}{% endfor %}{% endfor %}{{ o }}"),
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

      (new String'("`'x' in TEXT`, `'x' not in TEXT`, `'x' in LIST`"),
       new String'("{% if 'b' in 'abc' and 'z' not in 'abc' %}y{% endif %}"
                   & "{% set l = ['a', 'b'] %}{% if 'b' in l %}y{% endif %}"),
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

      (new String'("`\| first`, `\| last`, `\| min`"),
       new String'("{{ 'a-b'.split('-')|first }}{{ 'a-b'.split('-')|last }}"
                   & "{{ [3, 1, 2] | min }}{{ (messages | first).role }}"
                   & "{{ messages | last | tojson }}"),
       Works),

      (new String'("`.strip(S)`, `.lstrip(S)`, `.rstrip(S)`, `.split(S)`, "
                   & "`.startswith(S)`, `.endswith(S)`, `.replace(A, B)`"),
       new String'("{% set t = 'a|b|c' %}{% set m = 'a' %}"
                   & "{{ t.split('|')[0] }}{{ t.split('|')[-1] }}"
                   & "{{ t.split('|') | length }}"
                   & "{{ t.strip('a') }}{{ t.lstrip('a') }}"
                   & "{{ t.rstrip('c') }}"
                   & "{% if t.startswith(m) and t.endswith('c') %}y{% endif %}"
                   & "{{ t.replace('|', m ~ '-') }}"
                   & "{% for message in messages %}"
                   & "{% for tool_call in message.tool_calls %}"
                   & "{% for k, v in tool_call.arguments.items() %}"
                   & "{{ k }}{% endfor %}{% endfor %}{% endfor %}"),
       Works),

      (new String'("`strftime_now(FORMAT)`"),
       new String'("{{ strftime_now('%d %b %Y') }}"
                   & "{% if strftime_now is defined %}y{% endif %}"),
       Works),

      (new String'("`raise_exception(MESSAGE)`"),
       new String'("{{ raise_exception('no') }}"),
       Refused_At_Render),

      (new String'("`*`, `//`, `%`, `/`"),
       new String'("{{ 2 + 3 * 4 }}{{ (2 + 3) * 4 }}{{ -7 // 2 }}"
                   & "{{ -7 % 2 }}{{ 8 / 2 }}"),
       Works),

      (new String'("`\| lower`, `\| upper`, `\| capitalize`, `\| title`, "
                   & "`\| int`, `\| string`, `\| safe`, `\| default(X)`, "
                   & "`\| replace(A, B)`"),
       new String'("{{ 'Ab' | lower | upper }}{{ 'ab cd' | capitalize }}"
                   & "{{ 'ab cd' | title }}{{ '12x' | int }}"
                   & "{{ 'x' | string }}{{ 'x' | safe }}"
                   & "{{ '' | default('d') }}{{ 'a-b' | replace('-', '+') }}"),
       Works),

      (new String'("`{% set name %} ... {% endset %}`"),
       new String'("{% set x %}a{{ 1 + 1 }}{% endset %}{{ x | upper }}"),
       Works),

      (new String'("`{% macro name(p, q='x') %} ... {% endmacro %}` and "
                   & "`{{ name(a, b) }}`"),
       new String'("{% macro m(p, q='!') %}{{ p }}{{ q }}{% set o = 'i' %}"
                   & "{% endmacro %}{% set o = 'o' %}"
                   & "{{ m('a') }}{{ m('b', '?') | upper }}{{ o }}"),
       Works),

      (new String'("`{% for name in tools %}`"),
       new String'("{% for tool in tools %}{{ tool | tojson }}{% endfor %}"),
       Works),

      (new String'("`{% for name in message.tool_calls %}`, "
                   & "`message.tool_calls[i]`"),
       new String'("{% for message in messages %}"
                   & "{% for c in message.tool_calls %}"
                   & "{{ c.name }}{% endfor %}"
                   & "{% if message.tool_calls %}"
                   & "{{ message.tool_calls[0].name }}{% endif %}"
                   & "{% endfor %}"),
       Works),

      (new String'("`message.tool_calls`, `tool_call.name`, "
                   & "`tool_call.arguments`, `tool_call.function`"),
       new String'("{% for message in messages %}"
                   & "{% if message.tool_calls %}"
                   & "{% for tool_call in message.tool_calls %}"
                   & "{% if tool_call.function is defined %}"
                   & "{% set tool_call = tool_call.function %}{% endif %}"
                   & "{{ tool_call.name }}{{ tool_call.arguments | tojson }}"
                   & "{% for k, v in tool_call.arguments | items %}"
                   & "{{ k }}={{ v }}{% endfor %}"
                   & "{% endfor %}{% endif %}{% endfor %}"),
       Works),

      (new String'("`\| tojson`"),
       new String'("{{ 'text' | tojson }}{{ ['a', 1] | tojson }}"),
       Works),

      (new String'("List literals `['a', 'b']`, `[]`"),
       new String'("{% set l = ['a', 'b'] %}{% set none_at_all = [] %}"
                   & "{{ l }}{{ l | length }}{{ none_at_all | length }}"
                   & "{% for x in l %}{{ x }}{% endfor %}"
                   & "{% macro m(items) %}{{ items[1] }}{% endmacro %}"
                   & "{{ m(l) }}"),
       Works),

      (new String'("`NAME[EXPR]`, `NAME[-1]`, `a.b.c`, `LIST[i].field`, "
                   & "`LIST[i][j]`, `NAME['member']`"),
       new String'("{% set l = ['a', ['b', 'c']] %}{% set i = 1 %}"
                   & "{{ l[i] }}{{ l[i - 1] }}{{ l[-1] }}{{ l[9] }}"
                   & "{{ l[1][0] }}{{ l[0][0] }}"
                   & "{% set ns = namespace(a='x') %}{{ ns.a }}"
                   & "{{ messages[0].role[0] }}{{ messages[0]['role'][0] }}"
                   & "{{ 'a|b'.split('|')[1].upper() }}"
                   & "{{ messages[1].content }}"),
       Works),

      (new String'("`a == b`, `x is defined` and their like as values, "
                   & "`(A if C else B)`"),
       new String'("[{{ 1 == 1 }}][{{ nothing is defined }}][{{ true }}]"
                   & "{% set ok = 1 == 2 %}{% if ok %}T{% endif %}{{ ok }}"
                   & "{% if (1 == 1) != (2 == 3) %}y{% endif %}"
                   & "{% for message in messages %}"
                   & "{{ message.role + ('!' if loop.first else '') }}"
                   & "{% endfor %}"),
       Works),

      (new String'("`loop.previtem`, `loop.nextitem`"),
       new String'("{% for message in messages %}"
                   & "{% if loop.previtem and loop.previtem.role != 'tool' %}"
                   & "p{% endif %}{% if not loop.last and "
                   & "loop.nextitem.role == 'user' %}n{% endif %}"
                   & "{% endfor %}"),
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
                   & "{% set n = none %}{{ True }}{{ False }}{{ None }}"
                   & "{% set i = 1 %}{{ i + 1 }}{% if i is number %}n{% endif %}"
                   & "{% if i == '1' %}!{% endif %}"),
       Works),

      (new String'("`is defined`, `is none`, `is true`, `is false`, "
                   & "`is string`, `is number`, `is mapping`, `is iterable`, "
                   & "`is not ...`"),
       new String'("{% if not tools is defined %}{% set tools = none %}"
                   & "{% endif %}{% if tools is none %}a{% endif %}"
                   & "{% if bos_token is not none %}b{% endif %}"
                   & "{% if true is true and false is false %}c{% endif %}"
                   & "{% if bos_token is string %}d{% endif %}"
                   & "{% set l = [] %}{% if l is iterable and l is not "
                   & "mapping %}e{% endif %}"
                   & "{% if messages[0].nothing is defined %}!{% endif %}"),
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

      (new String'("`loop.first`, `loop.last`, `loop.index`, `loop.index0`, "
                   & "`loop.length`, `loop.revindex`, `loop.revindex0`"),
       new String'("{% for message in messages %}"
                   & "{% if loop.first %}f{% endif %}"
                   & "{% if loop.last %}l{% endif %}"
                   & "{{ loop.index }}{{ loop.index0 }}{{ loop.length }}"
                   & "{{ loop.revindex }}{{ loop.revindex0 }}{% endfor %}"),
       Works),

      (new String'("`{% break %}`, `{% continue %}`"),
       new String'("{% for i in range(5) %}{% if i == 1 %}{% continue %}"
                   & "{% endif %}{% if i == 3 %}{% break %}{% endif %}"
                   & "{{ i }}{% endfor %}"),
       Works),

      (new String'("`{% filter NAME %} ... {% endfilter %}`"),
       new String'("{% filter upper %}ab{{ 'c' }}{% endfilter %}"),
       Works),

      (new String'("`{% call name(a) %} ... {% endcall %}` and `caller()`"),
       new String'("{% macro box(t) %}<{{ t }}>{{ caller() }}</{{ t }}>"
                   & "{% endmacro %}{% call box('b') %}in{% endcall %}"),
       Works),

      (new String'("Mapping literals `{'a': 1}`, `.keys()`, `.values()`, "
                   & "`.get(k, d)`"),
       new String'("{% set d = {'a': 1, 'b': [1, 2]} %}{{ d }}{{ d | tojson }}"
                   & "{{ d.a + 1 }}{{ d.keys() | join }}{{ d.values() | length }}"
                   & "{{ d.get('b') }}{{ d.get('z', 'n') }}"),
       Works),

      (new String'("`\| join`, `\| map`, `\| select`, `\| reject`, "
                   & "`\| selectattr`, `\| rejectattr`, `\| sort`, "
                   & "`\| dictsort`, `\| indent`, `\| unique`, `\| list`"),
       new String'("{% set l = ['b', 'a', 'a'] %}{{ l | join(', ') }}"
                   & "{{ l | sort | join }}{{ l | sort(reverse=True) | join }}"
                   & "{{ l | unique | join }}{{ l | select('equalto', 'a')"
                   & " | list | length }}{{ l | reject('equalto', 'a') | join }}"
                   & "{{ messages | map(attribute='role') | join(',') }}"
                   & "{{ messages | selectattr('role', 'equalto', 'user')"
                   & " | map(attribute='content') | join }}"
                   & "{{ messages | rejectattr('role', 'equalto', 'user')"
                   & " | list | length }}"
                   & "{% for k, v in {'z': 1, 'a': 2} | dictsort %}{{ k }}"
                   & "{% endfor %}{{ 'a\nb' | indent(2) }}"
                   & "{{ 'abc' | list | join('.') }}"),
       Works),

      (new String'("`.upper()`, `.lower()`, `.title()`, `.capitalize()`"),
       new String'("{{ 'ab'.upper() }}{{ 'AB'.lower() }}{{ 'ab cd'.title() }}"
                   & "{{ 'ab'.capitalize() }}"),
       Works),

      (new String'("`{%- -%}` and `{{- -}}` whitespace control"),
       new String'("  {%- if true -%}  a  {%- endif -%}  {{- 'b' -}}  "),
       Works),

      (new String'("`include`, `import`, `extends`"),
       new String'("{% include 'other' %}"),
       Refused_At_Compile),

      (new String'("Other filters"),
       new String'("{{ bos_token | urlencode }}"),
       Refused_At_Render),

      (new String'("`.strftime` on anything, other function calls, a "
                   & "message or a list of them printed whole, indexing by a "
                   & "name that holds no number"),
       new String'("{{ messages[i]['role'] }}"),
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
