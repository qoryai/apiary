defmodule ApiaryWeb.Gettext.Backends do
  @moduledoc """
  The Gettext backends of the build: the core's, `ApiaryWeb.Gettext`, and the edition's
  (`c:ApiaryWeb.Edition.gettext_backend/0`), each with the catalogues of its own modules'
  sentences (`docs/lingo.md`).

  A module translates its own sentences with its own backend
  (`use Gettext, backend: ...`), and never needs this one. This is for a sentence the core
  translates without knowing whose it is: a changeset's error, which a core component
  shows on a form of the core's or of the edition's
  (`ApiaryWeb.CoreComponents.translate_error/1`). It is looked up in each backend in turn,
  the core's first, in the process's locale and down the chain of
  `ApiaryWeb.Gettext.Fallback`, and read from the first whose catalogues translate it;
  where none does, the first backend gives the source text, interpolated.
  """

  @doc "The backends of the build, the core's first, then the edition's when it has one."
  @spec all() :: [module, ...]
  def all do
    case ApiaryWeb.Edition.gettext_backend() do
      nil -> [ApiaryWeb.Gettext]
      edition -> Enum.uniq([ApiaryWeb.Gettext, edition])
    end
  end

  @doc """
  dgettext/4 is `Gettext.dgettext/4` of the first of `backends` whose catalogues translate
  `msgid` in `domain`, or of the first of them when none does.
  """
  @spec dgettext([module, ...], String.t(), String.t(), Gettext.bindings()) :: String.t()
  def dgettext([first | _] = backends, domain, msgid, bindings \\ %{}) do
    bindings = Map.new(bindings)

    backend =
      Enum.find(backends, first, fn backend ->
        match?(
          {:ok, _},
          backend.lgettext(Gettext.get_locale(backend), domain, nil, msgid, bindings)
        )
      end)

    Gettext.dgettext(backend, domain, msgid, bindings)
  end

  @doc """
  dngettext/6 is `Gettext.dngettext/6` of the first of `backends` whose catalogues
  translate `msgid` and `msgid_plural` in `domain`, or of the first of them when none
  does.
  """
  @spec dngettext(
          [module, ...],
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer,
          Gettext.bindings()
        ) :: String.t()
  def dngettext([first | _] = backends, domain, msgid, msgid_plural, n, bindings \\ %{}) do
    bindings = Map.new(bindings)

    backend =
      Enum.find(backends, first, fn backend ->
        locale = Gettext.get_locale(backend)
        match?({:ok, _}, backend.lngettext(locale, domain, nil, msgid, msgid_plural, n, bindings))
      end)

    Gettext.dngettext(backend, domain, msgid, msgid_plural, n, bindings)
  end
end
