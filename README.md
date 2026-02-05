# sgpu_metal

[sgpu](https://github.com/roeyb1/sgpu/) but for Metal 4.

Refreshingly simple graphics API inspired by Sebastian Aaltonen's [No Graphics API](https://www.sebastianaaltonen.com/blog/no-graphics-api).

## Run examples

You can compile and run each example individually:

```
./run_example 01_memory
./run_example 02_compute
./run_example 03_hello_square
```

Or to run all examples in a "single frame" test with memory leak checking:

```
./run_examples.sh
```

## Metal Bindings

Jai's compiler ships with older Metal bindings.
