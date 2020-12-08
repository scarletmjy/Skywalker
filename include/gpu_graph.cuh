// 10/03/2016
// Graph data structure on GPUs
#ifndef _GPU_GRAPH_H_
#define _GPU_GRAPH_H_
#include "graph.cuh"
#include "header.h"
#include "sampler_result.cuh"
#include "util.h"
#include <algorithm>
#include <iostream>

typedef uint index_t;
typedef unsigned int vtx_t;
typedef float weight_t;
typedef unsigned char bit_t;

#define INFTY (int)-1
#define BIN_SZ 64

enum class BiasType { Weight = 0, Degree = 1 };

// template<BiasType bias=BiasType::Weight>
class gpu_graph {
public:
  vtx_t *adj_list;
  weight_t *weight_list;
  index_t *beg_pos;
  vtx_t *degree_list;
  uint *outDegree;

  float *prob_array;
  uint *alias_array;
  char *valid;

  index_t vtx_num;
  index_t edge_num;
  index_t avg_degree;
  uint MaxDegree;

  Jobs_result<JobType::RW, uint> *result;
  // sample_result *result2;
  // BiasType bias;

  // float (gpu_graph::*getBias)(uint);

public:
  gpu_graph() {}
  gpu_graph(Graph *ginst) {
    vtx_num = ginst->numNode;
    edge_num = ginst->numEdge;
    // printf("vtx_num: %d\t edge_num: %d\n", vtx_num, edge_num);
    avg_degree = ginst->numEdge / ginst->numNode;

    // size_t weight_sz=sizeof(weight_t)*edge_num;
    size_t adj_sz = sizeof(vtx_t) * edge_num;
    size_t deg_sz = sizeof(vtx_t) * edge_num;
    size_t beg_sz = sizeof(index_t) * (vtx_num + 1);

    adj_list = ginst->adjncy;
    beg_pos = ginst->xadj;
    weight_list = ginst->adjwgt;
    MaxDegree = ginst->MaxDegree;
    // bias = static_cast<BiasType>(FLAGS_dw);
    // getBias= &gpu_graph::getBiasImpl;
    // (graph->*(graph->getBias))
  }
  __device__ __host__ ~gpu_graph() {}
  __device__ index_t getDegree(index_t idx) {
    return beg_pos[idx + 1] - beg_pos[idx];
  }
  // __host__ index_t getDegree_h(index_t idx) { return outDegree[idx]; }
  // __device__ float getBias(index_t id);
  __device__ float getBias(index_t dst, uint src = 0, uint idx = 0);

  // degree 2 [0 ,1 ]
  // < 1 [1]
  // 1
  __device__ bool BinarySearch(uint *ptr, uint size, int target) {
    uint tmp_size = size;
    uint *tmp_ptr = ptr;
    // printf("checking %d\t", target);
    uint itr = 0;
    while (itr < 50) {
      // printf("%u %u.\t",tmp_ptr[tmp_size / 2],target );
      if (tmp_ptr[tmp_size / 2] == target) {
        return true;
      } else if (tmp_ptr[tmp_size / 2] < target) {
        tmp_ptr += tmp_size / 2;
        if (tmp_size == 1) {
          return false;
        }
        tmp_size = tmp_size - tmp_size / 2;
      } else {
        tmp_size = tmp_size / 2;
      }
      if (tmp_size == 0) {
        return false;
      }
      itr++;
    }
    return false;
  }
  __device__ bool CheckConnect(int src, int dst) {
    // uint degree = getDegree(src);
    if (BinarySearch(adj_list + beg_pos[src], getDegree(src), dst)) {
      // paster()
      // printf("Connect %d %d \n", src, dst);
      return true;
    }
    // printf("not Connect %d %d \n", src, dst);
    return false;
  }
  __device__ float getBiasImpl(index_t idx) {
    return beg_pos[idx + 1] - beg_pos[idx];
  }
  __device__ index_t getOutNode(index_t idx, index_t offset) {
    return adj_list[beg_pos[idx] + offset];
  }
  __device__ vtx_t *getNeighborPtr(index_t idx) {
    return &adj_list[beg_pos[idx]];
  }
};

#endif
//  __device__ float getBias(index_t idx);
// __device__ float getBias(index_t idx, Jobs_result<JobType::RW, uint>
// result);
// __device__ float getBias(index_t idx, sample_result result);
//  {
//   return beg_pos[idx + 1] - beg_pos[idx];
// }
// template <BiasType bias>
// friend  __device__ float getBias(gpu_graph *g, index_t idx);
//  {
//   return g->beg_pos[idx + 1] - g->beg_pos[idx];
// }

// template <BiasType bias = BiasType::Degree>
// __device__ float getBiasImpl(index_t idx);

// __device__ index_t getBias(index_t idx) {
//   return getBiasImpl<static_cast<BiasType>(FLAGS_dw)>(idx);
// }
// __device__ bool CheckConnect(int src, int dst) {
//   uint degree = getDegree(src);
//   for (size_t i = 0; i < degree; i++) {
//     if (getOutNode(src, i) == dst)
//       return true;
//   }
//   return false;
// }
