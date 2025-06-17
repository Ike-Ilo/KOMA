PYTHON_INCLUDE=$(python3 -c "from sysconfig import get_paths as gp; print(gp()['include'])")
PYTHON_LIB="/usr/lib/x86_64-linux-gnu/libpython3.9.so"

cmake .. \
    -DBUILD_PYTHON_BINDINGS=ON \
    -DPYTHON_EXECUTABLE=$(which python3) \
    -DCMAKE_BUILD_TYPE=Release \
    -DPYTHON_INCLUDE_DIR=${PYTHON_INCLUDE} \
    -DPYTHON_LIBRARY=${PYTHON_LIB}

make -j2
make install
ldconfig