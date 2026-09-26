defmodule ApiaryWeb.Async do
  @moduledoc """
  `assign_async/3,4`, `start_async/3,4` and `stream_async/3,4` as a page of the console
  calls them: those of `Phoenix.LiveView`, with the function run under the organisation and
  workspace ids the LiveView's process carries in its Logger metadata
  (`Apiary.LogMetadata.carry/1`). The task LiveView starts has no metadata
  of its own, so without this a line logged by a page's async read would say no
  organisation.

  `use ApiaryWeb.Async` imports these in place of `Phoenix.LiveView`'s: `use ApiaryWeb,
  :live_view` and `:live_component` say it, and so does a module that imports
  `Phoenix.LiveView` for the pages (`ApiaryWeb.PolicyLive.Common`). They take the same arguments and make the same checks:
  LiveView looks for a use of `socket` in the function, which would copy the whole socket
  into the task, when the page is compiled, and, with `enable_expensive_runtime_checks`,
  for a socket or an assigns map among what the function captured when it runs. It is
  given the wrapped function, which it cannot look into, so both checks are made here on
  the function itself.
  """

  @replaced [
    assign_async: 3,
    assign_async: 4,
    start_async: 3,
    start_async: 4,
    stream_async: 3,
    stream_async: 4
  ]

  @doc """
  Imports `Phoenix.LiveView` without the functions this module stands in for, and this
  module in their place. After `use Phoenix.LiveView`, which imports all of it, or in a
  module that imports it for the pages. `use ApiaryWeb, :live_view` and `:live_component`
  say it.
  """
  defmacro __using__(_opts) do
    quote do
      import Phoenix.LiveView, except: unquote(@replaced)
      import ApiaryWeb.Async, warn: false
    end
  end

  @doc "`Phoenix.LiveView.assign_async/4`, the function run under the caller's ids."
  defmacro assign_async(socket, key_or_keys, func, opts \\ []) do
    wrap(:assign_async, [socket, key_or_keys], func, opts, __CALLER__)
  end

  @doc "`Phoenix.LiveView.start_async/4`, the function run under the caller's ids."
  defmacro start_async(socket, name, func, opts \\ []) do
    wrap(:start_async, [socket, name], func, opts, __CALLER__)
  end

  @doc "`Phoenix.LiveView.stream_async/4`, the function run under the caller's ids."
  defmacro stream_async(socket, name, func, opts \\ []) do
    wrap(:stream_async, [socket, name], func, opts, __CALLER__)
  end

  defp wrap(op, args, func, opts, env) do
    warn_socket_access(func, op, env)

    quote do
      Phoenix.LiveView.unquote(op)(
        unquote_splicing(args),
        ApiaryWeb.Async.carry(unquote(func), unquote(op)),
        unquote(opts)
      )
    end
  end

  @doc false
  # `Apiary.LogMetadata.carry/1`, after LiveView's runtime check of what the function
  # captured, when that check is on.
  @spec carry((-> result), atom()) :: (-> result) when result: term()
  def carry(func, op) when is_function(func, 0) do
    check_captures(func, op)
    Apiary.LogMetadata.carry(func)
  end

  if Application.compile_env(:phoenix_live_view, :enable_expensive_runtime_checks, false) do
    defp check_captures(func, op) do
      {:env, captured} = Function.info(func, :env)

      cond do
        Enum.any?(captured, &match?(%Phoenix.LiveView.Socket{}, &1)) ->
          IO.warn(
            "you are accessing the LiveView socket inside a function given to #{op}: " <>
              "the whole socket is copied to the task. Read what the function needs first."
          )

        Enum.any?(captured, &match?(%{__changed__: _}, &1)) ->
          IO.warn(
            "you are accessing an assigns map inside a function given to #{op}: " <>
              "the whole map is copied to the task. Read what the function needs first."
          )

        true ->
          :ok
      end
    end
  else
    defp check_captures(_func, _op), do: :ok
  end

  # LiveView's compile-time check, on the function as the page wrote it.
  defp warn_socket_access(func, op, env) do
    if match?({:fn, _, _}, func) or match?({:&, _, _}, func) do
      Macro.prewalk(func, fn
        {:socket, meta, context} = node when is_atom(context) ->
          IO.warn(
            "you are accessing the LiveView socket inside a function given to #{op}: " <>
              "the whole socket is copied to the task. Read what the function needs first.",
            Keyword.take(meta, [:line, :column]) ++ [line: env.line, file: env.file]
          )

          node

        other ->
          other
      end)
    end

    :ok
  end
end
