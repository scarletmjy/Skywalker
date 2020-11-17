#include "gpu_graph.cuh"
#include "sampler_result.cuh"
// #include "alias_table.cuh"
#include <random>

// struct sample_result;
// class Sampler;

template <typename T>
void printH(T *ptr, int size)
{
  T *ptrh = new T[size];
  HERR(cudaMemcpy(ptrh, ptr, size * sizeof(T), cudaMemcpyDeviceToHost));
  printf("printH: ");
  for (size_t i = 0; i < size; i++)
  {
    // printf("%d\t", ptrh[i]);
    std::cout << ptrh[i] << "\t";
  }
  printf("\n");
  delete ptrh;
}

class Sampler
{
public:
  gpu_graph ggraph;
  sample_result result;
  uint num_seed;

public:
  Sampler(gpu_graph graph) { ggraph = graph; }
  ~Sampler() {}
  void SetSeed(uint _num_seed, uint _hop_num, uint *_hops)
  {
    // printf("%s\t %s :%d\n", __FILE__, __PRETTY_FUNCTION__, __LINE__);
    num_seed = _num_seed;
    std::random_device rd;
    std::mt19937 gen(56);
    std::uniform_int_distribution<> dis(1, ggraph.vtx_num);
    uint *seeds = new uint[num_seed];
    for (int n = 0; n < num_seed; ++n)
    {

#ifdef check
      seeds[n] = n;
      // seeds[n] = 339;
#else
      seeds[n] = dis(gen);
#endif // check

      // h_sample_id[n] = 0;
      // h_depth_tracker[n] = 0;
      // printf("%d\n",seeds[n]);
    }
    // printf("first ten seed:");
    // for (int n = 0; n < 10; ++n) printf("%d \t",seeds[n]);
    // printf("\n");
    result.init(num_seed, _hop_num, _hops, seeds);
    // printf("first ten seed:");
    // printH(result.data,10 );
  }
  // void Start();
};

void Start(Sampler sampler);
