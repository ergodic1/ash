defmodule Ash.Flow do
  @moduledoc """
  A flow is a static definition of a set of steps in your system. ALPHA - do not use

  Flows are backed by `executors`, which determine how the workflow steps are performed.
  The executor can be overriden on invocation, but not all executors will be capable of running all flows.

  WARNING: this is *beyond* alpha. There are still active unknowns in the implementation, and the performance is entirely untested.

  Flow DSL documentation: `Ash.Flow`
  """

  @type t :: module

  use Ash.Dsl,
    default_extensions: [
      extensions: [Ash.Flow.Dsl]
    ]

  @spec run!(any, any, nil | maybe_improper_list | map) :: any
  def run!(flow, input, opts \\ []) do
    case run(flow, input, opts) do
      {:ok, result} ->
        result

      {:error, error} ->
        raise Ash.Error.to_error_class(error)
    end
  end

  def run(flow, input, opts \\ []) do
    unless Application.get_env(:ash, :allow_flow) do
      raise "Flows are highly unstable and must be explicitly enabled in configuration, `config :ash, :allow_flow`"
    end

    executor = opts[:executor] || Ash.Flow.Executor.AshEngine

    with {:ok, input} <- cast_input(flow, input),
         {:ok, built} <- executor.build(flow, input, opts) do
      executor.execute(built, input, opts)
    else
      {:error, error} ->
        {:error, error}
    end
  end

  defp cast_input(flow, params) do
    arguments = Ash.Flow.Info.arguments(flow)

    Enum.reduce_while(params, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      case Enum.find(arguments, &(&1.name == name || to_string(&1.name) == name)) do
        nil ->
          {:cont, {:ok, acc}}

        arg ->
          with {:ok, value} <- Ash.Changeset.cast_input(arg.type, value, arg.constraints, flow),
               {:constrained, {:ok, casted}}
               when not is_nil(value) <-
                 {:constrained, Ash.Type.apply_constraints(arg.type, value, arg.constraints)} do
            {:cont, {:ok, Map.put(acc, arg.name, casted)}}
          else
            {:constrained, {:ok, nil}} ->
              {:cont, {:ok, Map.put(acc, arg.name, nil)}}

            {:error, error} ->
              {:halt, {:error, error}}
          end
      end
    end)
  end

  @doc false
  def handle_before_compile(_opts) do
    quote bind_quoted: [] do
      {opt_args, args} =
        __MODULE__
        |> Ash.Flow.Info.arguments()
        |> Enum.split_with(& &1.allow_nil?)

      args = Enum.map(args, & &1.name)

      opt_args = Enum.map(opt_args, & &1.name)

      arg_vars = Enum.map(args, &{&1, [], Elixir})
      @doc Ash.Flow.Info.description(__MODULE__)

      def run!(unquote_splicing(arg_vars), input \\ %{}, opts \\ []) do
        {input, opts} =
          if opts == [] && Keyword.keyword?(input) do
            {%{}, input}
          else
            {input, opts}
          end

        opt_input =
          Enum.reduce(unquote(opt_args), input, fn opt_arg, input ->
            case Map.fetch(input, opt_arg) do
              {:ok, val} ->
                Map.put(input, opt_arg, val)

              :error ->
                case Map.fetch(input, to_string(opt_arg)) do
                  {:ok, val} ->
                    Map.put(input, opt_arg, val)

                  :error ->
                    input
                end
            end
          end)

        required_input =
          unquote(args)
          |> Enum.zip([unquote_splicing(arg_vars)])
          |> Map.new()

        all_input = Map.merge(required_input, opt_input)

        Ash.Flow.run!(__MODULE__, all_input, opts)
      end

      def run(unquote_splicing(arg_vars), input \\ %{}, opts \\ []) do
        {input, opts} =
          if opts == [] && Keyword.keyword?(input) do
            {%{}, input}
          else
            {input, opts}
          end

        opt_input =
          Enum.reduce(unquote(opt_args), input, fn opt_arg, input ->
            case Map.fetch(input, opt_arg) do
              {:ok, val} ->
                Map.put(input, opt_arg, val)

              :error ->
                case Map.fetch(input, to_string(opt_arg)) do
                  {:ok, val} ->
                    Map.put(input, opt_arg, val)

                  :error ->
                    input
                end
            end
          end)

        required_input =
          unquote(args)
          |> Enum.zip([unquote_splicing(arg_vars)])
          |> Map.new()

        all_input = Map.merge(required_input, opt_input)

        Ash.Flow.run(__MODULE__, all_input, opts)
      end
    end
  end

  def handle_modifiers(action_input) do
    do_handle_modifiers(action_input)
  end

  defp do_handle_modifiers(action_input)
       when is_map(action_input) and not is_struct(action_input) do
    Map.new(action_input, fn {key, value} ->
      new_key = do_handle_modifiers(key)
      new_val = do_handle_modifiers(value)
      {new_key, new_val}
    end)
  end

  defp do_handle_modifiers(action_input) when is_list(action_input) do
    Enum.map(action_input, &do_handle_modifiers(&1))
  end

  defp do_handle_modifiers({:_path, value, path}) do
    do_get_in(do_handle_modifiers(value), path)
  end

  defp do_handle_modifiers(action_input) when is_tuple(action_input) do
    List.to_tuple(do_handle_modifiers(Tuple.to_list(action_input)))
  end

  defp do_handle_modifiers(other), do: other

  @doc false
  def do_get_in(value, []), do: value

  def do_get_in(value, [key | rest]) when is_atom(key) and is_struct(value) do
    do_get_in(Map.get(value, key), rest)
  end

  def do_get_in(value, [key | rest]) do
    do_get_in(get_in(value, [key]), rest)
  end

  def remap_result_references(action_input, prefix) do
    do_remap_result_references(action_input, prefix)
  end

  defp do_remap_result_references(action_input, prefix)
       when is_map(action_input) and not is_struct(action_input) do
    Map.new(action_input, fn {key, value} ->
      new_key = do_remap_result_references(key, prefix)
      new_val = do_remap_result_references(value, prefix)
      {new_key, new_val}
    end)
  end

  defp do_remap_result_references(action_input, prefix) when is_list(action_input) do
    Enum.map(action_input, &do_remap_result_references(&1, prefix))
  end

  defp do_remap_result_references({:_path, value, path}, prefix) do
    {:_path, do_remap_result_references(value, prefix), do_remap_result_references(path, prefix)}
  end

  defp do_remap_result_references({:_result, step}, prefix) when is_function(prefix) do
    {:_result, prefix.(step)}
  end

  defp do_remap_result_references({:_result, step}, prefix) do
    {:_result, [prefix | List.wrap(step)]}
  end

  defp do_remap_result_references(action_input, input) when is_tuple(action_input) do
    List.to_tuple(do_remap_result_references(Tuple.to_list(action_input), input))
  end

  defp do_remap_result_references(other, _), do: other

  def set_dependent_values(action_input, input) do
    do_set_dependent_values(action_input, input)
  end

  defp do_set_dependent_values(action_input, input)
       when is_map(action_input) and not is_struct(action_input) do
    Map.new(action_input, fn {key, value} ->
      new_key = do_set_dependent_values(key, input)
      new_val = do_set_dependent_values(value, input)
      {new_key, new_val}
    end)
  end

  defp do_set_dependent_values(action_input, input) when is_list(action_input) do
    Enum.map(action_input, &do_set_dependent_values(&1, input))
  end

  defp do_set_dependent_values({:_path, value, path}, input) do
    {:_path, do_set_dependent_values(value, input), do_set_dependent_values(path, input)}
  end

  defp do_set_dependent_values({:_result, step}, input) do
    get_in(input, [:results, step])
  end

  defp do_set_dependent_values({:_element, step}, input) do
    get_in(input, [:elements, step])
  end

  defp do_set_dependent_values({:_range, start, finish}, input) do
    do_set_dependent_values(start, input)..do_set_dependent_values(finish, input)
  end

  defp do_set_dependent_values(action_input, input) when is_tuple(action_input) do
    List.to_tuple(do_set_dependent_values(Tuple.to_list(action_input), input))
  end

  defp do_set_dependent_values(other, _), do: other

  def handle_input_template(action_input, input) do
    {val, deps} = do_handle_input_template(action_input, input)
    {val, Enum.uniq(deps)}
  end

  defp do_handle_input_template(action_input, input)
       when is_map(action_input) and not is_struct(action_input) do
    Enum.reduce(action_input, {%{}, []}, fn {key, value}, {acc, deps} ->
      {new_key, key_deps} = do_handle_input_template(key, input)
      {new_val, val_deps} = do_handle_input_template(value, input)
      {Map.put(acc, new_key, new_val), deps ++ key_deps ++ val_deps}
    end)
  end

  defp do_handle_input_template(action_input, input) when is_list(action_input) do
    {new_items, deps} =
      Enum.reduce(action_input, {[], []}, fn item, {items, deps} ->
        {new_item, new_deps} = do_handle_input_template(item, input)

        {[new_item | items], new_deps ++ deps}
      end)

    {Enum.reverse(new_items), deps}
  end

  defp do_handle_input_template({:_path, value, path}, input) do
    {new_value, value_deps} = do_handle_input_template(value, input)
    {new_path, path_deps} = do_handle_input_template(path, input)
    {{:_path, new_value, new_path}, value_deps ++ path_deps}
  end

  defp do_handle_input_template({:_arg, name}, input) do
    {Map.get(input, name) || Map.get(input, to_string(name)), []}
  end

  defp do_handle_input_template({:_result, step}, _input) do
    {{:_result, step}, [{:_result, step}]}
  end

  defp do_handle_input_template(action_input, input) when is_tuple(action_input) do
    {list, deps} = do_handle_input_template(Tuple.to_list(action_input), input)
    {List.to_tuple(list), deps}
  end

  defp do_handle_input_template(other, _), do: {other, []}
end
