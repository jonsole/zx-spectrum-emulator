from setuptools import setup

setup(
    cffi_modules=["zxspectrum/_native/build.py:ffibuilder"],
)
