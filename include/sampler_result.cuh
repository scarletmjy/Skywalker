#pragma once
#include <cooperative_groups.h>
#include <gflags/gflags.h>
#include <omp.h>

#include "frontier.cuh"
#include "vec.cuh"
namespace cg = cooperative_groups;

DECLARE_int32(device);
DECLARE_double(hd);
DECLARE_bool(peritr);
DECLARE_bool(node2vec);
DECLARE_double(p);
DECLARE_double(q);
DECLARE_bool(umresult);
DECLARE_bool(built);

struct sample_job {
  uint idx;
  uint node_id;
  bool val;  //= false
};

struct sample_job_new {
  uint idx_in_frontier;
  uint instance_idx;
  bool val;  //= false
};

struct id_pair {
  uint idx, node_id;
  __device__ id_pair &operator=(uint idx) {
    this->idx = 0;
    this->node_id = 0;
    return *this;
  }
};

enum class JobType {
  NS,  // neighbour sampling
  LS,  // layer sampling
  RW,  // random walk
  NODE2VEC
};

template <typename T>
__global__ void init_range_d(T *ptr, size_t size, size_t offset = 0) {
  if (TID < size) {
    ptr[TID] = offset + TID;
  }
}
template <typename T>
void init_range(T *ptr, size_t size, size_t offset = 0) {
  init_range_d<T><<<size / 512 + 1, 512>>>(ptr, size, offset);
}

template <typename T>
__global__ void get_sum_d(T *ptr, size_t size, size_t *result) {
  size_t local = 0;
  for (size_t i = TID; i < size; i += gridDim.x * blockDim.x) {
    local += ptr[i];
  }
  __syncthreads();
  size_t tmp = blockReduce<float>(local);
  if (LTID == 0) {
    *result = tmp;
  }
}

template <typename T>
size_t get_sum(T *ptr, size_t size) {
  size_t *sum;
  CUDA_RT_CALL(MyCudaMallocManaged(&sum, sizeof(size_t)));
  get_sum_d<T><<<1, BLOCK_SIZE>>>(ptr, size, sum);
  CUDA_RT_CALL(cudaDeviceSynchronize());
  size_t t = *sum;
  return t;
}

static __global__ void initSeed2(uint *data, uint *seeds, size_t size,
                                 uint hop) {
  if (TID < size) {
    data[TID * hop] = seeds[TID];
  }
}

static __global__ void initSeed3(uint *data, uint *seeds, size_t size,
                                 uint hop) {
  if (TID < size) {
    data[TID] = seeds[TID];
  }
}

// template <JobType job, typename T>
// static __global__ void initStateSeed(SamplerState<job, T> *states, uint
// *seeds,
//                                      size_t size);

template <JobType job, typename T>
struct Jobs_result;

template <typename T>
struct Frontier {
  u64 *size;
  T *data;
  u64 capacity;
  void Allocate(size_t _size) {
    capacity = _size;
    CUDA_RT_CALL(MyCudaMalloc(&data, 3 * capacity * sizeof(T)));
    CUDA_RT_CALL(MyCudaMalloc(&size, 3 * sizeof(u64)));
  }
  __device__ void CheckActive(uint itr) {}
  __device__ void SetActive(uint itr, T idx) {
    size_t old = atomicAdd(&size[itr % 3], 1);
    data[capacity * (itr % 3) + old] = idx;
  }
  __device__ void Reset(uint itr) { size[itr % 3] = 0; }
  __device__ u64 Size(uint itr) { return size[itr % 3]; }
  __device__ T Get(uint itr, uint idx) {
    return data[capacity * (itr % 3) + idx];
  }
};
static __global__ void setFrontierSize(u64 *data, uint size) {
  if (TID == 0) data[0] = size;
}

template <JobType job, typename T>
struct SamplerState;

template <typename T>
struct SamplerState<JobType::NODE2VEC, T> {
  T last = 0;
  // bool alive = true;
};
// template <typename T> struct SamplerState<JobType::NODE2VEC, uint> {
//   // T *data;
//   uint depth = 0;
//   bool alive = true;
//   // void Allocate(uint size) { CUDA_RT_CALL(MyCudaMalloc(&data, size *
//   sizeof(T))); }
// };

// template<typename T>

template <typename T>
__global__ void printSizeK(T f) {
  f.printSize();
}

template <typename T>
struct Jobs_result<JobType::NS, T> {
  // using task_t = Task<JobType::RW, T>;
  u64 size;
  uint hop_num;
  uint capacity;
  uint *data;
  char *alive;
  uint *length;

  int *job_sizes = nullptr;
  uint device_id;
  uint length_per_sample = 0;
  uint *hops;
  uint *hops_h;
  uint *sample_lengths;  // format ( len(s1), len(s1.h1),....len(s1.hk),
                         // len(s2),... )
  uint size_of_sample_lengths;
  uint *offsets;
  uint *seeds;

#ifdef ADD_FRONTIER
  int *job_sizes_floor = nullptr;
#ifdef LOCALITY

  LocalitySampleFrontier<T> frontier;
  LocalitySampleFrontier<T> high_degree;
#else
  SampleFrontier<T> frontier;
  Vector_gmem<sampleJob<T>> *high_degrees;
  Vector_gmem<sampleJob<T>> *high_degrees_h;
#endif
#endif

  __host__ void printSize() {
    printSizeK<<<32, 1>>>(frontier);
#ifndef LOCALITY
    for (size_t i = 0; i < hop_num; i++) {
      printSizeK<<<32, 1>>>(high_degrees[i]);
    }

#else
    printSizeK<<<32, 1>>>(high_degree);
#endif
    CUDA_RT_CALL(cudaDeviceSynchronize());
  }

  __forceinline__ __device__ void SetSampleLength(uint sampleIdx, uint itr,
                                                  uint idx, uint v) {
    uint tmp = sampleIdx * size_of_sample_lengths + offsets[itr] + idx;
    sample_lengths[tmp] = v;
  }
  __device__ uint GetSampleLength(uint sampleIdx, uint itr, size_t idx) {
    // printf("size_of_sample_lengths %u\n",size_of_sample_lengths);
    uint tmp = sampleIdx * size_of_sample_lengths + offsets[itr] + idx;
    return sample_lengths[tmp];
  }

  Jobs_result() {}
  void Free() {
    if (alive != nullptr) CUDA_RT_CALL(cudaFree(alive));
    if (length != nullptr) CUDA_RT_CALL(cudaFree(length));
    if (data != nullptr) CUDA_RT_CALL(cudaFree(data));
    if (job_sizes != nullptr) CUDA_RT_CALL(cudaFree(job_sizes));
#ifdef ADD_FRONTIER
    if (job_sizes_floor != nullptr) CUDA_RT_CALL(cudaFree(job_sizes_floor));

#ifndef LOCALITY
    for (size_t i = 0; i < hop_num; i++) {
      high_degrees_h[i].Free();
    }
    if (high_degrees != nullptr) CUDA_RT_CALL(cudaFree(high_degrees));
#else
    high_degree.Free();
#endif
#endif
  }
  void init(uint _size, uint _hop_num, uint *_hops, uint *_seeds,
            uint _device_id = 0, uint num_vtx = 0) {
    int dev_id = omp_get_thread_num();
    CUDA_RT_CALL(cudaSetDevice(dev_id));
    device_id = _device_id;
    size = _size;
    // paster(_hop_num);
    hop_num = _hop_num;
    hops_h = new uint[hop_num];
    memcpy(hops_h, _hops, hop_num * sizeof(uint));
    CUDA_RT_CALL(MyCudaMalloc(&hops, hop_num * sizeof(uint)));
    CUDA_RT_CALL(
        cudaMemcpy(hops, _hops, hop_num * sizeof(uint), cudaMemcpyDefault));
    uint *offsets_h = new uint[hop_num];

    // LOG("alloc hops %d at %x\n", hop_num, hops);
    uint tmp = 1;
    for (size_t i = 0; i < hop_num; i++) {
      tmp *= _hops[i];
      offsets_h[i] = length_per_sample;
      length_per_sample += tmp;
    }
    tmp = 1;
    for (size_t i = 1; i < hop_num - 1; i++) {
      tmp += _hops[i];
    }
    size_of_sample_lengths = tmp;

    CUDA_RT_CALL(MyCudaMalloc(&offsets, hop_num * sizeof(uint)));
    CUDA_RT_CALL(cudaMemcpy(offsets, offsets_h, hop_num * sizeof(uint),
                            cudaMemcpyHostToDevice));
    CUDA_RT_CALL(MyCudaMalloc(&sample_lengths,
                              size * size_of_sample_lengths * sizeof(uint)));
    CUDA_RT_CALL(cudaMemset(sample_lengths, 0,
                            size * size_of_sample_lengths * sizeof(uint)));

    if (size * hop_num > 400000000) FLAGS_umresult = true;
    if (!FLAGS_umresult) {
      CUDA_RT_CALL(
          MyCudaMalloc(&data, size * length_per_sample * sizeof(uint)));
    } else {
      CUDA_RT_CALL(
          MyCudaMallocManaged(&data, size * length_per_sample * sizeof(uint)));
      CUDA_RT_CALL(cudaMemAdvise(data, size * length_per_sample * sizeof(uint),
                                 cudaMemAdviseSetAccessedBy, device_id));
    }
    // CUDA_RT_CALL(MyCudaMalloc(&length, size * sizeof(uint)));

    CUDA_RT_CALL(MyCudaMalloc(&seeds, size * sizeof(uint)));
    CUDA_RT_CALL(
        cudaMemcpy(seeds, _seeds, size * sizeof(uint), cudaMemcpyHostToDevice));

#ifdef ADD_FRONTIER
    if (!FLAGS_peritr) {
      // printf("%s:%d %s for %d\n", __FILE__, __LINE__, __FUNCTION__,0);

#ifndef LOCALITY
      high_degrees_h = new Vector_gmem<sampleJob<T>>[hop_num];
      int hdsize = 1;
      for (size_t i = 0; i < hop_num; i++) {
        hdsize *= hops_h[i];
        high_degrees_h[i].Allocate(MAX((size * FLAGS_hd * hdsize), 4000),
                                   device_id);
      }
      CUDA_RT_CALL(MyCudaMalloc(&high_degrees,
                                hop_num * sizeof(Vector_gmem<sampleJob<T>>)));
      CUDA_RT_CALL(cudaMemcpy(high_degrees, high_degrees_h,
                              hop_num * sizeof(Vector_gmem<sampleJob<T>>),
                              cudaMemcpyHostToDevice));
      frontier.Allocate(size, hops_h, num_vtx);

#ifndef NDEBUG
      LOG(" frontier overhead %d MB\n",
          MAX((size * FLAGS_hd * hdsize), 4000) / 1024 / 1024);
#endif
#else
      // high_degree = LocalitySampleFrontier<T>();
      high_degree.Allocate(size * FLAGS_hd * 2, num_vtx);
      frontier.Allocate(size, num_vtx);

#endif

      CUDA_RT_CALL(MyCudaMalloc(&job_sizes_floor, (hop_num) * sizeof(int)));
      CUDA_RT_CALL(MyCudaMalloc(&job_sizes, (hop_num) * sizeof(int)));

      frontier.Init(seeds, size);

      // copy seeds
      // if layout1, oor
      // CUDA_RT_CALL(cudaMemcpy(frontier.data, seeds, size * sizeof(uint),
      //                         cudaMemcpyHostToDevice));
      // setFrontierSize<<<1, 32>>>(frontier.size, size);
    }
#endif

    initSeed2<<<size / 1024 + 1, 1024>>>(data, seeds, size, length_per_sample);
    CUDA_RT_CALL(cudaDeviceSynchronize());
    CUDA_RT_CALL(cudaPeekAtLastError());
  }
  __host__ size_t GetSampledNumber(bool new_frontier = false) {
    // if (new_frontier)
    // return get_sum(frontier.sizes, frontier.hop_num); //normal frontier can
    // use this as well?
    // else
    // printH(hops, hop_num);
    // printH(sample_lengths, size * size_of_sample_lengths);
    return get_sum(sample_lengths, size * size_of_sample_lengths);
  }
  __device__ void AddActive(uint itr, uint sampleIdx, uint offset,
                            uint local_offset, uint candidate,
                            bool should_add = true, uint limit = 0) {
    // int old = atomicAdd(&job_sizes[current_itr + 1], 1);
    // *(getNextAddr(current_itr) + old) = candidate;
    // if (itr >= 2 && should_add)
    //   printf(
    //       "add itr %u sampleIdx %u offset %u local_offset %u adding "
    //       "%u\n ",
    //       itr, sampleIdx, offset, local_offset,  candidate);
    uint tmp = offset * hops[itr] + local_offset;
    // if (!sampleIdx)  // offset == 1 || && itr == 1 && (offset == 0)
    //   printf("itr %u sampleIdx %u offset %u local_offset %u loc %u
    //   adding%u\n",
    //          itr, sampleIdx, offset, local_offset, tmp, candidate);
    *GetDataPtr(sampleIdx, itr, tmp) = candidate;
    if (should_add) frontier.Add(sampleIdx, tmp, itr, candidate);
    // printf("Add new ele %u with degree %d\n", candidate,  );
  }

  __forceinline__ __device__ sampleJob<T> requireOneJob(uint itr = 0) {
#ifdef LOCALITY
    auto tmp = frontier.requireOneJob();
    return tmp;
#else
    return frontier.requireOneJob(itr);
#endif
  }

#ifndef LOCALITY
  __forceinline__ __device__ void AddHighDegree(uint current_itr,
                                                sampleJob<T> tmp) {
    // printf("AddHighDegree %u %u \n",current_itr,instance_idx);
    // sampleJob<T> tmp = {instance_idx, offset, src_id, current_itr, true};
    high_degrees[current_itr].Add(tmp);
  }
  __forceinline__ __device__ sampleJob<T> requireOneHighDegreeJob(
      uint current_itr) {
    sampleJob<T> job;
    // int old = atomicSub(&job_sizes[current_itr], 1) - 1;
    job.val = false;
    int old = atomicAdd(high_degrees[current_itr].floor, 1);
    if (old < high_degrees[current_itr].Size()) {
      job = high_degrees[current_itr].Get(old);
      job.val = true;
    } else {
      int old = atomicAdd(high_degrees[current_itr].floor, -1);
      // int old = my_atomicSub(high_degrees[current_itr].floor, 1);
      // job.val = false;
    }
    return job;
  }
#else
  __forceinline__ __device__ void AddHighDegree(uint current_itr,
                                                sampleJob<T> tmp) {
    high_degree.Add(
        tmp.instance_idx, tmp.offset, tmp.itr,
        tmp.src_id);  //(uint instance_idx, uint offset, uint itr, T src_id)
  }
  __forceinline__ __device__ sampleJob<T> requireOneHighDegreeJob(
      uint current_itr) {
    return high_degree.requireOneJob();
  }
#endif

  __device__ void PrintResult() {
    if (LTID == 0) {
      for (int j = 0; j < MIN(4, size); j++) {
        printf("\n%dth sample src: %u, 1-hop len: %u \n", j, GetData(j, 0, 0),
               GetSampleLength(j, 0, 0));

        printf("\t 1-hop : ");
        for (uint k = 0; k < MIN(GetSampleLength(j, 0, 0), 30); k++) {
          printf("%u \t", GetData(j, 1, k));
        }
        printf("\n");
        for (uint i = 0; i < GetSampleLength(j, 0, 0); i++) {
          printf("\t %u th 2-hop [%u]: ", i, GetData(j, 1, i));

          for (uint k = 0; k < MIN(GetSampleLength(j, 1, i), 30); k++) {
            printf("%u \t", GetData(j, 2, k + i * hops[2]));
          }
          printf("\n");
        }
      }
    }
  }
  __device__ T *GetDataPtr(uint sampleIdx, uint itr, size_t idx) {
    return data + sampleIdx * length_per_sample + offsets[itr] + idx;
  }
  __device__ T GetData(uint sampleIdx, uint itr, size_t idx) {
    return data[sampleIdx * length_per_sample + offsets[itr] + idx];
  }
  __host__ void DebugInfo() {
    // paster(length_per_sample);
    // paster(size_of_sample_lengths);
    // printf("hops ");
    // for (size_t i = 0; i < hop_num; i++) {
    //   printf("%d\t", _hops[i]);
    // }
    // printf("hop_num ");
    // printf("offsets ");
    // for (size_t i = 0; i < hop_num; i++) {
    //   printf("%d\t", offsets_h[i]);
    // }
    // for (size_t itr = 0; itr < 3; itr++)
    // for (size_t sampleIdx = 0; sampleIdx < 3; sampleIdx++) {
    //   int itr = 1, idx = 0;
    //   printf("offsets[itr] %u\n ", offsets_h[itr]);
    //   printf("offsets[itr]+ idx %u\n ", offsets_h[itr] + idx);
    //   printf("sampleIdx * size_of_sample_lengths + offsets_h[itr] + idx
    //   %u\n",
    //          sampleIdx * size_of_sample_lengths + offsets_h[itr] + idx);
    //   uint tmp = sampleIdx * size_of_sample_lengths + offsets_h[itr] + idx;
    //   // printf("tmp %u\n ", tmp);
    //   printf("sampleIdx %u itr %u idx %u loc %u \n", sampleIdx, itr, idx,
    //   tmp);
    // }
    // printf("\n ");
  }
};

template <typename T>
struct Jobs_result<JobType::RW, T> {
  // using task_t = Task<JobType::RW, T>;
  u64 size;
  uint hop_num;
  uint capacity;
  uint *data;
  char *alive;
  uint *length;
  // uint *frontier;
  Frontier<T> frontier;
  Vector_gmem<uint> *high_degrees;
  int *job_sizes_floor = nullptr;
  int *job_sizes = nullptr;
  uint *data2;
  uint device_id;
  int *lock;

  SamplerState<JobType::NODE2VEC, T> *state;
  float p = 2.0, q = 0.5;
  Vector_gmem<uint> *high_degrees_h;

  Jobs_result() {}
  void Free() {
    if (alive != nullptr) CUDA_RT_CALL(cudaFree(alive));
    if (length != nullptr) CUDA_RT_CALL(cudaFree(length));
    if (data != nullptr) CUDA_RT_CALL(cudaFree(data));
    if (job_sizes != nullptr) CUDA_RT_CALL(cudaFree(job_sizes));
    if (job_sizes_floor != nullptr) CUDA_RT_CALL(cudaFree(job_sizes_floor));

    for (size_t i = 0; i < hop_num; i++) {
      high_degrees_h[i].Free();
    }
    if (high_degrees != nullptr) CUDA_RT_CALL(cudaFree(high_degrees));
  }
  void init(uint _size, uint _hop_num, uint *seeds, uint _device_id = 0) {
    int dev_id = omp_get_thread_num();
    CUDA_RT_CALL(cudaSetDevice(dev_id));
    device_id = _device_id;
    size = _size;
    hop_num = _hop_num;
    // paster(hop_num);
    if (size * hop_num > 400000000) FLAGS_umresult = true;
    if (!FLAGS_umresult) {
      CUDA_RT_CALL(MyCudaMalloc(&data, size * hop_num * sizeof(uint)));
    } else {
      CUDA_RT_CALL(MyCudaMallocManaged(&data, size * hop_num * sizeof(uint)));
      CUDA_RT_CALL(cudaMemAdvise(data, size * hop_num * sizeof(uint),
                                 cudaMemAdviseSetAccessedBy, device_id));
    }
    CUDA_RT_CALL(MyCudaMalloc(&alive, size * sizeof(char)));
    CUDA_RT_CALL(cudaMemset(alive, 1, size * sizeof(char)));
    CUDA_RT_CALL(MyCudaMalloc(&length, size * sizeof(uint)));
    // CUDA_RT_CALL(cudaMemset(length, 0, size * sizeof(uint)));
    CUDA_RT_CALL(MyCudaMalloc(&lock, 100 * sizeof(int)));
    CUDA_RT_CALL(cudaMemset(lock, 0, 100 * sizeof(int)));

    if (FLAGS_node2vec) {
      CUDA_RT_CALL(MyCudaMalloc(
          &state, size * sizeof(SamplerState<JobType::NODE2VEC, T>)));
      p = FLAGS_p;
      q = FLAGS_q;
    }

    {
      if (!FLAGS_umresult) {
        CUDA_RT_CALL(MyCudaMalloc(&data2, size * hop_num * sizeof(uint)));
      } else {
        CUDA_RT_CALL(
            MyCudaMallocManaged(&data2, size * hop_num * sizeof(uint)));
        CUDA_RT_CALL(cudaMemAdvise(data2, size * hop_num * sizeof(uint),
                                   cudaMemAdviseSetAccessedBy, device_id));
      }

      init_range(data2, size);
      // CUDA_RT_CALL(cudaMemcpy(data2, seeds, size * sizeof(uint),
      //                  cudaMemcpyHostToDevice));

      high_degrees_h = new Vector_gmem<uint>[hop_num];

      for (size_t i = 0; i < hop_num; i++) {
        high_degrees_h[i].Allocate(MAX((size * FLAGS_hd), 4000), device_id);
      }
      CUDA_RT_CALL(
          MyCudaMalloc(&high_degrees, hop_num * sizeof(Vector_gmem<uint>)));
      CUDA_RT_CALL(cudaMemcpy(high_degrees, high_degrees_h,
                              hop_num * sizeof(Vector_gmem<uint>),
                              cudaMemcpyHostToDevice));
      CUDA_RT_CALL(MyCudaMalloc(&job_sizes_floor, (hop_num) * sizeof(int)));
      CUDA_RT_CALL(MyCudaMalloc(&job_sizes, (hop_num) * sizeof(int)));
    }

    if (FLAGS_peritr) {
      frontier.Allocate(size);
      // copy seeds
      // if layout1, oor
      CUDA_RT_CALL(cudaMemcpy(frontier.data, seeds, size * sizeof(uint),
                              cudaMemcpyHostToDevice));
      setFrontierSize<<<1, 32>>>(frontier.size, size);
    }
    // uint *seeds_g;
    // CUDA_RT_CALL(MyCudaMalloc(&seeds_g, size * sizeof(uint)));
    // CUDA_RT_CALL(cudaMemcpy(seeds_g, seeds, size * sizeof(uint),
    //                  cudaMemcpyHostToDevice));
    // initSeed3<<<size / 1024 + 1, 1024>>>(data, seeds_g, size, hop_num);

    if (true)
      initSeed2<<<size / 1024 + 1, 1024>>>(data, seeds, size, hop_num);
    else
      CUDA_RT_CALL(
          cudaMemcpy(data, seeds, size * sizeof(uint), cudaMemcpyHostToDevice));
    CUDA_RT_CALL(cudaDeviceSynchronize());
    CUDA_RT_CALL(cudaPeekAtLastError());
  }
  __device__ void AddHighDegree(uint current_itr, uint instance_idx) {
    // printf("AddHighDegree %u %u \n",current_itr,instance_idx);
    high_degrees[current_itr].Add(instance_idx);
  }
  __host__ size_t GetSampledNumber() {
    // paster((get_sum(length, size)));
    // paster((get_sum(job_sizes, hop_num)));
    return get_sum(length, size);
  }
  __device__ void setAddrOffset() {
    // printf("%s:%d %s\n", __FILE__, __LINE__, __FUNCTION__);
    // paster(size);
    job_sizes[0] = size;
    // uint64_t offset = 0;
    // uint64_t cum = size;
    // hops_acc[0]=1;
    for (size_t i = 0; i < hop_num; i++) {
      // if (i!=0) hops_acc[i]
      // addr_offset[i] = offset;
      // cum *= hops[i];
      // offset += cum;
      job_sizes_floor[i] = 0;
    }
  }

  __device__ void PrintResult() {
    if (LTID == 0) {
      // printf("seeds \n");
      // for (size_t i = 0; i < MIN(3, size); i++) {
      //   printf("%u \t", GetData(0, i));
      // }
      for (int j = 0; j < size; j++) {
        // for (int j = 0; j < MIN(3, size); j++) {
        printf("\n%drd path len %u \n", j, length[j]);
        for (size_t i = 0; i < MIN(length[j], hop_num); i++) {
          printf("%u \t", GetData(i, j));
        }
        printf("\n");
      }
    }
  }
  __device__ T *GetDataPtr(uint itr, size_t idx) {
    return data + itr + idx * hop_num;
  }
  __device__ T GetData(uint itr, size_t idx) {
    return data[itr + idx * hop_num];
  }
  // __device__ T *GetDataPtr(uint itr, size_t idx) {
  //   return data + itr * size + idx;
  // }
  // __device__ T GetData(uint itr, size_t idx) {
  //   return data[itr * size + idx];
  // }
  __device__ uint getNodeId(uint idx, uint hop) {
    // paster(addr_offset[hop]);
    return data[hop * size + idx];
  }
  __device__ uint getNodeId2(uint idx, uint hop) {
    // paster(addr_offset[hop]);
    return data2[hop * size + idx];
  }

  //   struct sample_job_new {
  //   uint idx_in_frontier;
  //   uint instance_idx;
  //   bool val;  //= false
  // };
  __device__ struct sample_job_new requireOneHighDegreeJob(uint current_itr) {
    sample_job_new job;
    job.val = false;
    int old = atomicAdd(high_degrees[current_itr].floor, 1);
    if (old < high_degrees[current_itr].Size()) {
      job.instance_idx = high_degrees[current_itr].Get(old);
      job.val = true;
    } else {
      int old = atomicAdd(high_degrees[current_itr].floor, -1);
      // int old = my_atomicSub(high_degrees[current_itr].floor, 1);
    }
    return job;
  }
  __device__ struct sample_job_new requireOneHighDegreeJob_block(
      uint current_itr) {
    sample_job_new job;
    job.val = false;
    int old;
    cg::grid_group grid_threads = cg::this_grid();
    if (threadIdx.x == 0) {
      old = atomicAdd(high_degrees[current_itr].floor, 1);
    }
    grid_threads.sync();
    if (threadIdx.x == 0) {
      if (old < high_degrees[current_itr].Size()) {
        job.instance_idx = high_degrees[current_itr].Get(old);
        job.val = true;
      } else {
        atomicAdd(high_degrees[current_itr].floor, -1);
        // int old = my_atomicSub(high_degrees[current_itr].floor, 1);
      }
    }
    grid_threads.sync();
    return job;
  }
  __device__ struct sample_job_new requireOneJob_warp(
      uint current_itr)  // uint hop
  {
    // use grid sync will lead to deadlock here
    //  while (atomicCAS(&lock[current_itr], 0, 1) == 1)
    //    ;
    sample_job_new job;
    job.val = false;
    cg::grid_group grid_threads = cg::this_grid();
    int old;
    if (threadIdx.x % WARP_SIZE == 0) {
      // printf("requireOneJob for itr %u\n", current_itr);
      // paster(job_sizes[current_itr]);
      // int old = atomicSub(&job_sizes[current_itr], 1) - 1;
      old = atomicAdd(&job_sizes_floor[current_itr], 1);
    }
    grid_threads.sync();
    if (threadIdx.x % WARP_SIZE == 0) {
      if (old < job_sizes[current_itr]) {
        // printf("poping wl ele idx %d\n", old);
        job.idx_in_frontier = (uint)old;
        job.instance_idx = getNodeId2(old, current_itr);
        job.val = true;
        // printf("poping wl ele node_id %d\n", job.node_id);
      } else {
        atomicSub(&job_sizes_floor[current_itr], 1);
      }
    }
    grid_threads.sync();
    // atomicExch(&lock[current_itr], 0);
    return job;
  }

  __device__ struct sample_job_new requireOneJob(uint current_itr)  // uint hop
  {
    // use grid sync will lead to deadlock here
    // while (atomicCAS(&lock[current_itr], 0, 1) == 1)
    //   ;
    sample_job_new job;
    job.val = false;
    // printf("requireOneJob for itr %u\n", current_itr);
    // paster(job_sizes[current_itr]);
    // int old = atomicSub(&job_sizes[current_itr], 1) - 1;
    int old = atomicAdd(&job_sizes_floor[current_itr], 1);
    if (old < job_sizes[current_itr]) {
      // printf("poping wl ele idx %d\n", old);
      job.idx_in_frontier = (uint)old;
      job.instance_idx = getNodeId2(old, current_itr);
      job.val = true;
      // printf("poping wl ele node_id %d\n", job.node_id);
    } else {
      int old = atomicSub(&job_sizes_floor[current_itr], 1);
    }
    // atomicExch(&lock[current_itr], 0);
    return job;
  }
  __device__ void AddActive(uint current_itr, uint candidate) {
    int old = atomicAdd(&job_sizes[current_itr + 1], 1);
    // printf("AddActive itr:%u,old:%d,candidate:%u\n", current_itr, old,
    //        candidate);
    *(getNextAddr(current_itr) + old) = candidate;
    // printf("Add new ele %u with degree %d\n", candidate,  );
  }
  __device__ void NextItr(uint &current_itr) {
    current_itr++;
    // printf("start itr %d at block %d \n", current_itr, blockIdx.x);
  }
  __device__ uint *getNextAddr(uint hop) {
    // uint offset =  ;// + hops[hop] * idx;
    return &data2[(hop + 1) * size];
  }
};

struct sample_result {
  uint size;
  uint hop_num;
  uint *hops = nullptr;
  uint *hops_h;
  // uint *hops_acc;
  uint *addr_offset = nullptr;
  uint *data = nullptr;
  int *job_sizes = nullptr;
  int *job_sizes_h = nullptr;
  int *job_sizes_floor = nullptr;
  uint capacity;
  uint device_id;
  uint *seeds;

  Vector_gmem<uint> *high_degrees;
  Vector_gmem<uint> *mid_degrees;

  // uint current_itr = 0;
  sample_result() {}
  // void Free()
  // void AssemblyFeature(float * ptr, float * feat, ){

  // }
  __device__ int GetJobSize(uint itr) { return job_sizes[itr]; }
  void Free() {
    if (hops != nullptr) CUDA_RT_CALL(cudaFree(hops));
    if (addr_offset != nullptr) CUDA_RT_CALL(cudaFree(addr_offset));
    if (data != nullptr) {
      CUDA_RT_CALL(cudaFree(data));
      data = nullptr;
    }
    if (job_sizes != nullptr) CUDA_RT_CALL(cudaFree(job_sizes));
    if (job_sizes_floor != nullptr) CUDA_RT_CALL(cudaFree(job_sizes_floor));
    if (job_sizes_h != nullptr) delete[] job_sizes_h;
  }
  void init(uint _size, uint _hop_num, uint *_hops, uint *_seeds,
            uint _device_id = 0) {
    int dev_id = omp_get_thread_num();
    CUDA_RT_CALL(cudaSetDevice(dev_id));
    device_id = _device_id;
    Free();
    size = _size;
    hop_num = _hop_num;
    seeds = _seeds;
    hops_h = _hops;
    CUDA_RT_CALL(MyCudaMalloc(&hops, hop_num * sizeof(uint)));
    CUDA_RT_CALL(cudaMemcpy(hops, _hops, hop_num * sizeof(uint),
                            cudaMemcpyHostToDevice));
    CUDA_RT_CALL(MyCudaMalloc(&addr_offset, hop_num * sizeof(uint)));
    Vector_gmem<uint> *high_degrees_h = new Vector_gmem<uint>[hop_num];
    Vector_gmem<uint> *mid_degrees_h = new Vector_gmem<uint>[hop_num];
    // for (size_t i = 0; i < hop_num; i++) {
    // }
    uint64_t offset = 0;
    uint64_t cum = size;
    for (size_t i = 0; i < hop_num; i++) {
      cum *= _hops[i];
      if (FLAGS_bias && !FLAGS_built) {
        high_degrees_h[i].Allocate(MAX((cum * FLAGS_hd), 4000), device_id);
        mid_degrees_h[i].Allocate(MAX((cum * FLAGS_hd), 4000), device_id);
      }
      offset += cum;
    }
    capacity = offset;
    if (!FLAGS_built) {
      CUDA_RT_CALL(
          MyCudaMalloc(&high_degrees, hop_num * sizeof(Vector_gmem<uint>)));
      CUDA_RT_CALL(cudaMemcpy(high_degrees, high_degrees_h,
                              hop_num * sizeof(Vector_gmem<uint>),
                              cudaMemcpyHostToDevice));
      CUDA_RT_CALL(
          MyCudaMalloc(&mid_degrees, hop_num * sizeof(Vector_gmem<uint>)));
      CUDA_RT_CALL(cudaMemcpy(mid_degrees, mid_degrees_h,
                              hop_num * sizeof(Vector_gmem<uint>),
                              cudaMemcpyHostToDevice));
      CUDA_RT_CALL(MyCudaMalloc(&data, capacity * sizeof(uint)));
      CUDA_RT_CALL(
          cudaMemcpy(data, seeds, size * sizeof(uint), cudaMemcpyHostToDevice));
      job_sizes_h = new int[hop_num];
      job_sizes_h[0] = size;
      CUDA_RT_CALL(MyCudaMalloc(&job_sizes, (hop_num) * sizeof(int)));
      CUDA_RT_CALL(MyCudaMalloc(&job_sizes_floor, (hop_num) * sizeof(int)));
    }
  }
  __host__ size_t GetSampledNumber() { return get_sum(job_sizes, hop_num); }
  __device__ void PrintResult() {
    if (LTID == 0) {
      printf("job_sizes \n");
      printD(job_sizes, hop_num);
      uint total = 0;
      for (size_t i = 0; i < hop_num; i++) {
        total += job_sizes[i];
      }
      printf("total sampled %u \n", total);
      // printf("job_sizes_floor \n");
      // printD(job_sizes_floor, hop_num);
      // printf("result: \n");
      // printD(data, MIN(capacity, 30));
    }
  }
  __device__ void setAddrOffset() {
    job_sizes[0] = size;
    uint64_t offset = 0;
    uint64_t cum = size;
    // hops_acc[0]=1;
    for (size_t i = 0; i < hop_num; i++) {
      // if (i!=0) hops_acc[i]
      addr_offset[i] = offset;
      cum *= hops[i];
      offset += cum;
      job_sizes_floor[i] = 0;
    }
  }
  __device__ uint *getNextAddr(uint hop) { return &data[addr_offset[hop + 1]]; }
  __device__ uint getNodeId(uint idx, uint hop) {
    return data[addr_offset[hop] + idx];
  }
  __device__ uint *getAddrOfInstance(uint idx, uint hop) {
    return data + addr_offset[hop] + idx * hops[hop];
  }
  __device__ uint getDataOfInstance(uint idx, uint hop, uint offset) {
    return data[addr_offset[hop] + idx * hops[hop] + offset];
  }
  __device__ uint getHopSize(uint hop) { return hops[hop]; }
  __device__ uint getFrontierSize(uint hop) {
    uint64_t cum = size;
    for (size_t i = 0; i < hop; i++) {
      cum *= hops[i];
    }
    return cum;
  }
  __device__ void AddHighDegree(uint current_itr, uint node_id) {
    high_degrees[current_itr].Add(node_id);
  }
  __device__ void AddMidDegree(uint current_itr, uint node_id) {
    mid_degrees[current_itr].Add(node_id);
  }
  __device__ struct sample_job requireOneHighDegreeJob(uint current_itr) {
    sample_job job;
    // int old = atomicSub(&job_sizes[current_itr], 1) - 1;
    job.val = false;
    int old = atomicAdd(high_degrees[current_itr].floor, 1);
    if (old < high_degrees[current_itr].Size()) {
      job.node_id = high_degrees[current_itr].Get(old);
      job.val = true;
    } else {
      int old = atomicAdd(high_degrees[current_itr].floor, -1);
      // int old = my_atomicSub(high_degrees[current_itr].floor, 1);
      // job.val = false;
    }
    return job;
  }
  __device__ struct sample_job requireOneMidDegreeJob(uint current_itr) {
    sample_job job;
    // int old = atomicSub(&job_sizes[current_itr], 1) - 1;
    job.val = false;
    int old = atomicAdd(mid_degrees[current_itr].floor, 1);
    if (old < mid_degrees[current_itr].Size()) {
      job.node_id = mid_degrees[current_itr].Get(old);
      job.val = true;
    } else {
      int old = atomicAdd(mid_degrees[current_itr].floor, -1);
      // int old = my_atomicSub(mid_degrees[current_itr].floor, 1);
      // job.val = false;
    }
    return job;
  }
  __device__ struct sample_job requireOneJob(uint current_itr)  // uint hop
  {
    sample_job job;
    job.val = false;
    int old = atomicAdd(&job_sizes_floor[current_itr], 1);
    if (old < job_sizes[current_itr]) {
      job.idx = (uint)old;
      job.node_id = getNodeId(old, current_itr);
      job.val = true;
      // printf("send one job %d in itr %u\n", job.node_id, current_itr);
    } else {
      int old = atomicSub(&job_sizes_floor[current_itr], 1);
    }
    return job;
  }
  __device__ bool checkFinish(uint current_itr) {
    if (job_sizes_floor[current_itr] < job_sizes[current_itr] ||
        *high_degrees[current_itr].floor < high_degrees[current_itr].Size())
      return false;
    return true;
  }
  __device__ void AddActive(uint current_itr, uint candidate) {
    int old = atomicAdd(&job_sizes[current_itr + 1], 1);
    *(getNextAddr(current_itr) + old) = candidate;
    // printf("Add new ele %u with degree %d\n", candidate,  );
  }
  __device__ void NextItr(uint &current_itr) { current_itr++; }
};
