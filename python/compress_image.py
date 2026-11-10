#!/usr/bin/env python3
"""Compress and/or resize an image. Requires Pillow (see requirements.txt)."""

import os
import sys

from PIL import Image, ImageOps


def get_size_format(b, factor=1024, suffix="B"):
    """
    Scale bytes to its proper byte format
    e.g:
        1253656 => '1.20MB'
        1253656678 => '1.17GB'
    """
    for unit in ["", "K", "M", "G", "T", "P", "E", "Z"]:
        if b < factor:
            return f"{b:.2f}{unit}{suffix}"
        b /= factor
    return f"{b:.2f}Y{suffix}"


def target_size(size, new_size_ratio, width, height):
    """Work out the new (width, height), or None if the image keeps its size.

    An explicit width and/or height wins over the ratio. If only one of the
    two is given, the other follows from the aspect ratio.
    """
    orig_width, orig_height = size
    if width and height:
        return (width, height)
    if width:
        return (width, max(1, round(orig_height * width / orig_width)))
    if height:
        return (max(1, round(orig_width * height / orig_height)), height)
    if new_size_ratio < 1.0:
        return (max(1, int(orig_width * new_size_ratio)), max(1, int(orig_height * new_size_ratio)))
    return None


def compress_img(image_name, new_size_ratio=1.0, quality=90, width=None, height=None, to_jpg=True, force=False):
    # split the filename and extension
    filename, ext = os.path.splitext(image_name)
    # make new filename appending _compressed to the original file name
    if to_jpg:
        # change the extension to JPEG
        new_filename = f"{filename}_compressed.jpg"
    else:
        # retain the same extension of the original image
        new_filename = f"{filename}_compressed{ext}"
    if os.path.exists(new_filename) and not force:
        print(f"[!] Output file already exists: {new_filename} (use --force to overwrite)", file=sys.stderr)
        return 1

    # load the image to memory
    img = Image.open(image_name)
    # apply the EXIF orientation: the tag is not written to the new file, so
    # photos taken in portrait mode would otherwise come out rotated
    img = ImageOps.exif_transpose(img)
    # print the original image shape
    print("[*] Image shape:", img.size)
    # get the original image size in bytes
    image_size = os.path.getsize(image_name)
    # print the size before compression/resizing
    print("[*] Size before compression:", get_size_format(image_size))

    new_size = target_size(img.size, new_size_ratio, width, height)
    if new_size:
        img = img.resize(new_size, Image.LANCZOS)
        # print new image shape
        print("[+] New Image shape:", img.size)

    # JPEG has no transparency and no palette: put transparent images on a
    # white background instead of letting the transparent parts turn black
    if os.path.splitext(new_filename)[1].lower() in (".jpg", ".jpeg") and img.mode not in ("RGB", "L"):
        if img.mode in ("RGBA", "LA") or (img.mode == "P" and "transparency" in img.info):
            rgba = img.convert("RGBA")
            background = Image.new("RGB", rgba.size, (255, 255, 255))
            background.paste(rgba, mask=rgba.getchannel("A"))
            img = background
        else:
            img = img.convert("RGB")

    # save the image with the corresponding quality and optimize set to True
    img.save(new_filename, quality=quality, optimize=True)
    print("[+] New file saved:", new_filename)
    # get the new image size in bytes
    new_image_size = os.path.getsize(new_filename)
    # print the new size in a good format
    print("[+] Size after compression:", get_size_format(new_image_size))
    # calculate the saving bytes
    saving_diff = new_image_size - image_size
    # print the saving percentage
    print(f"[+] Image size change: {saving_diff/image_size*100:.2f}% of the original image size.")
    return 0


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Simple Python script for compressing and resizing images")
    parser.add_argument("image", help="Target image to compress and/or resize")
    parser.add_argument("-j", "--to-jpg", action="store_true", help="Whether to convert the image to the JPEG format")
    parser.add_argument("-q", "--quality", type=int, help="Quality ranging from a minimum of 0 (worst) to a maximum of 95 (best). Default is 90", default=90)
    parser.add_argument("-r", "--resize-ratio", type=float, help="Resizing ratio from 0 to 1, setting to 0.5 will multiply width & height of the image by 0.5. Default is 1.0", default=1.0)
    parser.add_argument("-w", "--width", type=int, help="The new width of the image. Without --height the aspect ratio is kept. Overrides --resize-ratio")
    parser.add_argument("-hh", "--height", type=int, help="The new height of the image. Without --width the aspect ratio is kept. Overrides --resize-ratio")
    parser.add_argument("-f", "--force", action="store_true", help="Overwrite the output file if it already exists")
    args = parser.parse_args()
    if not 0 <= args.quality <= 95:
        parser.error("--quality must be between 0 and 95")
    if not 0 < args.resize_ratio <= 1:
        parser.error("--resize-ratio must be greater than 0 and at most 1")
    if (args.width is not None and args.width < 1) or (args.height is not None and args.height < 1):
        parser.error("--width and --height must be positive")
    # print the passed arguments
    print("="*50)
    print("[*] Image:", args.image)
    print("[*] To JPEG:", args.to_jpg)
    print("[*] Quality:", args.quality)
    print("[*] Resizing ratio:", args.resize_ratio)
    if args.width:
        print("[*] Width:", args.width)
    if args.height:
        print("[*] Height:", args.height)
    print("="*50)
    # compress the image
    sys.exit(compress_img(args.image, args.resize_ratio, args.quality, args.width, args.height, args.to_jpg, args.force))
