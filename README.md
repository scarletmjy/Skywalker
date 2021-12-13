# Skywalker

This is the repo for Skywalker, an Efficient Alias-method-based Graph Sampling and Random Walk framework on GPUs. 

## Introduction

Graph sampling and random walk operations, capturing the structural properties of graphs, are playing an important role today as we cannot directly adopt computing-intensive
algorithms on large-scale graphs. Existing system frameworks for these tasks are not only spatially and temporally inefficient, but many also lead to biased results. This paper presents Skywalker, a high-throughput, quality-preserving random walk and sampling framework based on GPUs. Skywalker makes three key contributions: first, it takes the first step to realize efficient biased sampling with the alias method on a GPU. Second, it introduces well-crafted load-balancing techniques to effectively utilize the massive parallelism of GPUs. Third, it accelerates alias table construction and reduce the GPU memory requirement with efficient memory management scheme. We show that Skywalker
greatly outperforms the state-of-the-art CPU-based and GPUbased baselines, in a wide spectrum of workload scenarios.

For details, please first refer to our 2021 PACT paper ["Skywalker: Efficient Alias-Method-Based Graph Sampling and Random Walk on GPUs"](https://ieeexplore.ieee.org/document/9563020) by Pengyu Wang, Chao Li, Jing Wang, Taolei Wang, Lu Zhang, Jingwen Leng, Quan Chen, and Minyi Guo. If you have any questions, please be free to contact us.

Beyond the contributions mentioned before, we further extend the framework to multi-gpu version and make a series of optimizations. The new work, named Skywalker+, has been submitted to TPDS.

## Setup
```
git clone https://github.com/wpybtw/skywalker_artifact --recursive
```

Note that Cmake is not correctly setted yet. We use cmake to build glfags and then make. 
```
cd build
cmake ..
make -j
cd ..
make
```

## Dataset 
When evaluating Skywalker, we use 7 commonly used Graph datasets:  web-Google, Livejournal, Orkut, Arabic-2005, UK-2005, Friendster, and SK-2005. The datasets can be downloaded from [SNAP](http://snap.stanford.edu/data/index.html) and [Webgraph](http://law.di.unimi.it/datasets.php). You can also execute Skywalker on your preferred datasets, as long as the datasets are processed correctly as mentioned in the section of Preprosessing.


## Preprocessing
Skywalker uses [Galios](https://iss.oden.utexas.edu/?p=projects/galois) graph format (.gr) as the input. Other formats like Edgelist (form [SNAP](http://snap.stanford.edu/data/index.html)) or Matrix Market can be transformed into it with GALOIS' graph-convert tool. Compressed graphs like [Webgraph](http://law.di.unimi.it/datasets.php) need to be uncompressed first.
Here is an example:
```
wget http://snap.stanford.edu/data/wiki-Vote.txt.gz
gzip -d wiki-Vote.txt.gz
$GALOIS_PATH/build/tools/graph-convert/graph-convert -edgelist2gr  ~/data/wiki-Vote.txt  ~/data/wiki-Vote.gr
```
## Execution
We implemented four different algorithms in Skywalker, namely DeepWalk, PPR, Node2vec and Neighbour Sampling all based on alias method. We support both online and offline sampling, that's constructing the alias table on the fly or for all vertices in one graph dataset at once as a preprocessing procedure. The source code files are placed under ``` ./src``` and ```./include``` folders. The configuration of Skywalker is set through gflags, and the default values are written in ```main.cu``` in the src folder. You can change the configuration simply by editting the command line.  
