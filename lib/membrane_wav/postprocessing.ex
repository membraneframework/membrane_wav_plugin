defmodule Membrane.WAV.Postprocessing do
  @moduledoc """
  Module responsible for post-processing serialized WAV files.

  Due to the fact that `Membrane.WAV.Serializer` creates WAV file with incorrect `file length` and
  `data length` blocks in the header, post-processing is needed. `fix_wav_header/1` fixes that
  problem.

  Header description can be found in `Membrane.WAV.Parser`.
  """

  @type fix_error :: {:error, File.posix() | :invalid_file | :badarg | :terminated} | IO.nodata()

  @doc """
  Fixes header of the WAV file located in `path`.
  """
  @spec fix_wav_header(String.t()) :: :ok | fix_error()
  def fix_wav_header(path) do
    with {:ok, file_length} <- get_file_length(path),
         {:ok, file} <- File.open(path, [:binary, :read, :write]),
         {:ok, header_length} <- get_header_length(file),
         data_length = file_length - header_length,
         :ok <- update_file(file, file_length, header_length, data_length) do
      File.close(file)
    end
  end

  defp get_file_length(path) do
    with {:ok, info} <- File.stat(path) do
      {:ok, info.size}
    end
  end

  defp get_header_length(file) do
    with "RIFF" <- IO.binread(file, 4),
         {:ok, _new_position} <- :file.position(file, 8),
         <<"WAVE", "fmt ", format_chunk_size::32-little>> <- IO.binread(file, 12),
         next_chunk_position = 20 + format_chunk_size,
         {:ok, current_position} <- :file.position(file, next_chunk_position),
         binary when is_binary(binary) <- IO.binread(file, 8),
         {:ok, header_length} <- check_fact_and_data(file, binary, current_position) do
      {:ok, header_length}
    else
      binary when is_binary(binary) -> {:error, :invalid_file}
      error -> error
    end
  end

  defp check_fact_and_data(file, binary, current_position) do
    case binary do
      <<"fact", fact_chunk_length::32-little>> ->
        data_position = current_position + 8 + fact_chunk_length

        with {:ok, _new_position} <- :file.position(file, data_position),
             <<"data", _rest::32>> <- IO.binread(file, 8) do
          {:ok, data_position + 8}
        end

      <<"data", _rest::32>> ->
        {:ok, current_position + 8}

      _unexpected_data ->
        {:error, :invalid_file}
    end
  end

  defp update_file(file, file_length, header_length, data_length) do
    with {:ok, _new_position} <- :file.position(file, 4),
         # subtracting 8 bytes as `file_length` field doesn't include "RIFF" header and the field itself
         :ok <- IO.binwrite(file, <<file_length - 8::32-little>>),
         {:ok, _new_position} <- :file.position(file, header_length - 4) do
      IO.binwrite(file, <<data_length::32-little>>)
    end
  end
end
