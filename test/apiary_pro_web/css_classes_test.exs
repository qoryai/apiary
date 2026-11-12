defmodule ApiaryProWeb.CssClassesTest do
  @moduledoc """
  The edition's rules, the end of `assets/css/app.css`, redefine no class of the core's
  rules before them. A rule of the edition's for a class the core also defines reaches
  the core's markup wherever it appears, on the edition's pages and on the core's pages
  the edition serves, and the core's rules for that class reach the edition's markup.
  The edition once named its lock line `.q-who`, the core's run lane name, and both rules
  met on both elements.

  A class both stylesheets define holds when every selector of the edition's that styles it is
  scoped: besides that class, the selector names a class only the edition defines or a core
  component's root (`@core_roots`), outside `:not()` and the other functional
  pseudo-classes. `.q-clients .q-toggle-description` would style the core's switch text
  inside the edition's block only; `.q-who { ... }` and `.q-who span { ... }` restyle the
  core's lane name everywhere. Or the class is on `@allowed`, with the reason the edition's rule
  is meant.

  The test reads the source: the edition's rules are the end of `assets/css/app.css`, from the
  line that starts them (`@pro_start`), and the core's are the rest of that file and the
  other `*.css` under `assets/css`. Comments
  and strings are blanked, braces are walked through `@layer` and `@media`, and every
  class of every selector counts, in compound and descendant selectors and inside
  `:is()`, `:where()`, `:not()` and `:has()`; attribute selectors are not classes.
  A rule nested in another style rule is read on its own, without its parent's scope.
  """
  use ExUnit.Case, async: true

  @pro_root Path.expand("../..", __DIR__)
  @css_dir Path.join(@pro_root, "assets/css")
  @app_css Path.join(@css_dir, "app.css")

  # The comment that starts the edition's rules in `assets/css/app.css`.
  @pro_start "/* ======== The edition's rules"

  # The class on the root element of a core function component that the edition renders, with
  # the component. A rule of the edition's under one adjusts that component, everywhere it is
  # drawn, as the core itself would, and touches nothing else. Add a root here only with
  # its component.
  @core_roots %{
    "q-find" => "ApiaryWeb.CoreComponents.list_search/1",
    "q-toggle-line" => "ApiaryWeb.CoreComponents.switch/1"
  }

  # Classes both stylesheets define, where the edition's rule is meant: each with why. An entry
  # here is not checked for scope, so prefer a scoped selector or a name of the edition's.
  @allowed %{
    "q-nm" =>
      "the edition wraps the People name cell below 600 px of table, and only when it holds the " <>
        "member's workspaces (`.q-member-access`), so they sit under the email and Level " <>
        "and the menu stay in the row"
  }

  test "the edition's stylesheet redefines no class of the core's" do
    pro = scan_pro()
    core = scan_core()
    pro_classes = defined(pro)
    core_classes = defined(core)

    # The scan finds the classes there are: if it found none, it would prove nothing.
    assert MapSet.size(pro_classes) > 5
    assert MapSet.size(core_classes) > 500

    shared = MapSet.intersection(pro_classes, core_classes)

    anchors =
      pro_classes
      |> MapSet.difference(core_classes)
      |> MapSet.union(MapSet.new(Map.keys(@core_roots)))

    held = MapSet.difference(shared, MapSet.new(Map.keys(@allowed)))

    unscoped =
      for {path, line, selector} <- pro, class <- unscoped(selector, held, anchors) do
        ".#{class} in `#{selector}` at #{Path.relative_to(path, @pro_root)}:#{line}"
      end

    assert unscoped == [], """
    The edition's stylesheet styles classes the core's also defines, unscoped, so each rule
    reaches the core's markup wherever it appears, and the core's rules reach the edition's:

      #{Enum.join(unscoped, "\n  ")}

    Rename the edition's class to one the core does not use (as `.q-who` became `.q-acts-note`),
    or scope the selector under a class only the edition defines or a core component's root
    (@core_roots in #{Path.relative_to(__ENV__.file, @pro_root)}), or add the class to
    @allowed there with the reason the edition's rule is meant.
    """
  end

  test "the allowed classes and the core's roots are classes the stylesheets define" do
    pro_classes = defined(scan_pro())
    core_classes = defined(scan_core())
    shared = MapSet.intersection(pro_classes, core_classes)

    # An entry for a class the edition no longer styles would let a later rule for it through.
    assert Enum.reject(Map.keys(@allowed), &(&1 in shared)) == []
    assert Enum.reject(Map.keys(@core_roots), &(&1 in core_classes)) == []
  end

  test "the scan reads every selector's classes, and a shared class is held to its scope" do
    css = """
    /* .q-note { } */
    @import "a.css";
    @layer qory {
      .q-a, .q-b:is(.q-c, .q-d) > span[class~="q-e"] { content: ".q-f; {"; }
      @media (min-width: 1px) {
        .q-g:not(.q-h)
          .q-i { color: red; }
      }
    }
    """

    assert for({line, selector} <- rules(css), do: {line, classes(selector)}) == [
             {4, ["q-a"]},
             {4, ["q-b", "q-c", "q-d"]},
             {6, ["q-g", "q-h", "q-i"]}
           ]

    shared = MapSet.new(~w(q-who q-root q-root-i))
    anchors = MapSet.new(~w(q-pro q-root))
    unscoped = &unscoped(&1, shared, anchors)

    assert unscoped.(".q-who") == ["q-who"]
    assert unscoped.(".q-who:hover") == ["q-who"]
    assert unscoped.(".q-who span") == ["q-who"]
    assert unscoped.(".q-who:not(.q-pro)") == ["q-who"]
    assert unscoped.(".q-root-i .q-who") == ["q-who"]
    assert unscoped.(".q-pro .q-who") == []
    assert unscoped.(".q-pro > .q-who::before") == []
    assert unscoped.(".q-who.q-pro") == []
    assert unscoped.(".q-who .q-pro") == []
    assert unscoped.(".q-root .q-root-i") == []
  end

  # Each style rule's selectors of the edition's, one complex selector each, with its file and the
  # line its rule starts on: `assets/css/app.css` from `@pro_start` on, the lines before it
  # kept as empty lines so the line numbers are the file's.
  defp scan_pro do
    {core, pro} = split_app_css()

    for {line, selector} <- rules(String.duplicate("\n", newlines(core)) <> pro),
        do: {@app_css, line, selector}
  end

  # The core's: `assets/css/app.css` before `@pro_start`, and every other `*.css` there.
  defp scan_core do
    {core, _pro} = split_app_css()

    others =
      for path <- Path.wildcard(Path.join(@css_dir, "*.css")),
          path != @app_css,
          {line, selector} <- rules(File.read!(path)),
          do: {path, line, selector}

    for({line, selector} <- rules(core), do: {@app_css, line, selector}) ++ others
  end

  defp split_app_css do
    case String.split(File.read!(@app_css), @pro_start, parts: 2) do
      [core, pro] -> {core, @pro_start <> pro}
      [_whole] -> flunk("#{@app_css} has no line that starts the edition's rules: #{@pro_start}")
    end
  end

  defp defined(scanned) do
    for {_path, _line, selector} <- scanned,
        class <- classes(selector),
        into: MapSet.new(),
        do: class
  end

  # The shared classes `selector` styles that it does not scope. It styles the classes of
  # its last compound, or, where that compound names none of its own (`.q-who span`),
  # every class it names. One is scoped when the selector names an anchor besides it,
  # outside functional pseudo-classes.
  defp unscoped(selector, shared, anchors) do
    selector = Regex.replace(~r/\[[^\]]*\]/, selector, "")

    subject = selector |> outside_parens(&(&1 in ~c" >+~")) |> List.last()

    styled =
      if own_classes(subject) == [], do: classes(selector), else: classes(subject)

    for class <- styled,
        class in shared,
        not Enum.any?(own_classes(selector), &(&1 != class and &1 in anchors)),
        do: class
  end

  # Every style rule's selectors with the line the rule starts on: the text before each
  # `{` since the last `{`, `}` or `;`, unless it is an at-rule's.
  defp rules(css) do
    css = blank(css)

    ~r/[{};]/
    |> Regex.scan(css, return: :index)
    |> Enum.reduce({0, 1, []}, fn [{at, 1}], {start, line, acc} ->
      prelude = binary_part(css, start, at - start)
      trimmed = String.trim(prelude)

      acc =
        if binary_part(css, at, 1) == "{" and trimmed != "" and
             not String.starts_with?(trimmed, "@") do
          leading = byte_size(prelude) - byte_size(String.trim_leading(prelude))
          rule_line = line + newlines(binary_part(prelude, 0, leading))
          selectors = trimmed |> String.split() |> Enum.join(" ") |> outside_parens(&(&1 == ?,))
          Enum.reverse(for(selector <- selectors, do: {rule_line, selector}), acc)
        else
          acc
        end

      {at + 1, line + newlines(prelude <> binary_part(css, at, 1)), acc}
    end)
    |> elem(2)
    |> Enum.reverse()
  end

  defp newlines(text), do: length(:binary.matches(text, "\n"))

  # Comments and the text of strings as spaces, so the offsets and lines stay.
  defp blank(css) do
    Regex.replace(~r{/\*.*?(?:\*/|\z)|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'}s, css, fn
      "/*" <> _ = comment ->
        spaces(comment)

      <<quote, _::binary>> = string ->
        <<quote>> <> spaces(binary_part(string, 1, byte_size(string) - 2)) <> <<quote>>
    end)
  end

  defp spaces(text), do: String.replace(text, ~r/[^\n]/, " ")

  # The parts of `text` split at the characters `split?` takes, outside any parentheses.
  defp outside_parens(text, split?) do
    {parts, part, _depth} =
      for <<c <- text>>, reduce: {[], [], 0} do
        {parts, part, depth} ->
          cond do
            c == ?( -> {parts, [part, c], depth + 1}
            c == ?) -> {parts, [part, c], depth - 1}
            depth == 0 and split?.(c) -> {[part | parts], [], depth}
            true -> {parts, [part, c], depth}
          end
      end

    for part <- Enum.reverse([part | parts]),
        part = part |> IO.iodata_to_binary() |> String.trim(),
        part != "",
        do: part
  end

  # Every class `selector` names, in order, attribute selectors left out.
  defp classes(selector) do
    ~r/\.((?:[A-Za-z_]|-[A-Za-z_-]|\\.)(?:[\w-]|\\.)*)/
    |> Regex.scan(Regex.replace(~r/\[[^\]]*\]/, selector, ""), capture: :all_but_first)
    |> Enum.map(fn [class] -> String.replace(class, "\\", "") end)
    |> Enum.uniq()
  end

  # The classes `selector` names outside the arguments of functional pseudo-classes.
  defp own_classes(selector) do
    selector |> strip_parens() |> classes()
  end

  defp strip_parens(text) do
    case Regex.replace(~r/\([^()]*\)/, text, "") do
      ^text -> text
      stripped -> strip_parens(stripped)
    end
  end
end
