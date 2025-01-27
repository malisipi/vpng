module vpng

import os

fn parse_(filename string) ?PngFile {
	file := os.read_file(filename) or {
		return none
	}
	mut file_bytes := []u8{len: file.len}
	for i, b in file {
		file_bytes[i] = u8(b)
	}
	read_signature(file_bytes[ .. 8]) or {
		return none
	}
	mut png := read_chunks(file_bytes[8 .. ])
	png.channels = match png.ihdr.color_type {
		3 { 1 } // Indexed
		0 { 1 } // Grayscale
		4 { 2 } // Grayscale Alpha
		2 { 3 } // TrueColor
		6 { 4 } // TrueColor Alpha
		else { 1 } // TODO ERROR
	}
	png.pixel_type = match png.ihdr.color_type {
		3 { PixelType.indexed } // Indexed
		0 { PixelType.grayscale } // Grayscale
		4 { PixelType.grayscalealpha } // Grayscale Alpha
		2 { PixelType.truecolor } // TrueColor
		6 { PixelType.truecoloralpha } // TrueColor Alpha
		else { PixelType.grayscale } // TODO ERROR
	}
	png.raw_bytes = decompress_idat(png)
	png.pixels = read_bytes(mut png)
	mut plte := []TrueColor{}
	for i := 0; i < png.plte.len; i += 3 {
		plte << TrueColor {
			red: png.plte[i]
			green: png.plte[i + 1]
			blue: png.plte[i + 2]
		}
	}
	return PngFile{
		width: png.ihdr.width
		height: png.ihdr.height
		pixels: png.pixels
		pixel_type: png.pixel_type
		ihdr: png.ihdr
		palette: plte
	}
}

fn read_signature(signature []u8) ?bool {
	is_good := signature == png_signature
	if !is_good {
		println('Wrong PNG signature')
		return none
	}
	return true
}

fn read_ihdr(chunk_data []u8) IHDR {
	return IHDR{
		width: byte_to_int(chunk_data[ .. 4])
		height: byte_to_int(chunk_data[4 .. 8])
		bit_depth: chunk_data[8]
		color_type: chunk_data[9]
		compression_method: chunk_data[10]
		filter_method: chunk_data[11]
		interlace_method: chunk_data[12]
	}
}

fn byte_a(r int, c int, png InternalPngFile) int {
	if c >= png.channels {
		return png.unfiltered_bytes[r * png.stride + c - png.channels]
	} else {
		return 0
	}
}

fn byte_b(r int, c int, png InternalPngFile) int {
	if r > 0 {
		return png.unfiltered_bytes[(r - 1) * png.stride + c]
	} else {
		return 0
	}
}

fn byte_c(r int, c int, png InternalPngFile) int {
	if r > 0 && c >= png.channels {
		return png.unfiltered_bytes[(r - 1) * png.stride + c - png.channels]
	} else {
		return 0
	}
}

fn abs(val int) int {
	if val < 0 {
		return -val
	} else {
		return val
	}
}

fn paeth(a int, b int, c int) int {
	p := a + b - c
	pa := abs(p - a)
	pb := abs(p - b)
	pc := abs(p - c)
	mut pr := 0
	if pa <= pb && pa <= pc {
		pr = a
	} else if pb <= pc {
		pr = b
	} else {
		pr = c
	}
	return pr
}

fn read_bytes(mut png InternalPngFile) []Pixel {
	png.stride = png.ihdr.width * png.channels
	mut i := 0
	for r in 0 .. (png.ihdr.height) {
		filter_type := png.raw_bytes[i]
		i++
		for c in 0 .. (png.stride) {
			filt := png.raw_bytes[i]
			i++
			new_byte := match filter_type {
				0 { filt }
				1 { filt + byte_a(r, c, png) }
				2 { filt + byte_b(r, c, png) }
				3 { filt + (byte_a(r, c, png) + byte_b(r, c, png)) / 2 }
				else { filt + paeth(byte_a(r, c, png), byte_b(r, c, png), byte_c(r, c, png)) }
			}
			png.unfiltered_bytes << u8(new_byte & 0xff)
		}
	}
	mut res := []Pixel{}
	for index := 0; index < png.unfiltered_bytes.len; index += png.channels {
		match png.ihdr.color_type {
			3 { // Indexed
				res << Indexed{
					index: png.unfiltered_bytes[index]
				}
			}
			0 { // Grayscale
			}
			4 { // Grayscale Alpha
			}
			2 { // TrueColor
				res << TrueColor{
					red: png.unfiltered_bytes[index]
					green: png.unfiltered_bytes[index + 1]
					blue: png.unfiltered_bytes[index + 2]
				}
			}
			6 { // TrueColor Alpha
				res << TrueColorAlpha{
					red: png.unfiltered_bytes[index]
					green: png.unfiltered_bytes[index + 1]
					blue: png.unfiltered_bytes[index + 2]
					alpha: png.unfiltered_bytes[index + 3]
				}
			}
			else {}
		}
	}
	return res
}

fn read_chunks(file []u8) InternalPngFile {
	mut index := 0
	mut png := InternalPngFile{}
	for index < file.len {
		chunk_size := byte_to_int(file[index .. index + 4])
		index += 4
		name := file[index .. index + 4].bytestr()
		if name == 'IEND' {
			break
		}
		index += 4
		chunk_data := file[index .. index + chunk_size]
		match name {
			'IEND' {
				break
			}
			'IHDR' {
				png.ihdr = read_ihdr(chunk_data)
			}
			'PLTE' {
				png.plte << chunk_data
			}
			'IDAT' {
				png.idat_chunks << chunk_data
			}
			else { // println("Chunk $name not handled")
			}
		}
		index += chunk_size
		index += 4
	}
	return png
}

fn decompress_idat(png InternalPngFile) []u8 {
	out_len := (png.ihdr.width * png.ihdr.height) * png.channels + png.ihdr.height
	out := unsafe {malloc(out_len)}
	infstream := C.z_stream_s{
		zalloc: 0
		zfree: 0
		opaque: 0
		avail_in: u32(png.idat_chunks.len)
		next_in: png.idat_chunks.bytestr().str
		avail_out: u32(out_len)
		next_out: out
	}
	C.inflateInit(&infstream)
	C.inflate(&infstream, 0)
	C.inflateEnd(&infstream)
	mut out_bytes := []u8{len: out_len}
	for i in 0 .. (out_len) {
		unsafe {
			out_bytes[i] = u8(out[i])
		}
	}
	return out_bytes
}
