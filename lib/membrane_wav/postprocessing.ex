defmodule Membrane.WAV.Postprocessing do
  @moduledoc """
  Module responsible for post-processing serialized WAV files.

  Due to the fact that `Membrane.WAV.Serializer` creates WAV file with incorrect `file length` and
  `data length` blocks in the header, post-processing is needed. `correct_wav_header/1` fixes that
  problem.

  Header description can be found in `Membrane.WAV.Parser`.
  """

  @doc """
  Fixes header of the WAV file located in `path`.
  """
  @spec correct_wav_header(String.t()) :: :ok
  def correct_wav_header(path) do
    with {:ok, info} <- File.stat(path),
         {:ok, file} <- File.open(path, [:binary, :read, :write]) do
      file_length = info.size
      header_length = get_header_length(file, 0)
      data_length = file_length - header_length

      :file.position(file, 4)
      IO.binwrite(file, <<file_length - 8::32-little>>)

      :file.position(file, header_length - 4)
      IO.binwrite(file, <<data_length::32-little>>)

      File.close(file)

      :ok
    end
  end

  defp get_header_length(file, acc) do
    case IO.binread(file, 4) do
      # previous chunks, "data" and block with data length
      "data" -> acc + 8
      _not_data -> get_header_length(file, acc + 4)
    end
  end
end
