// includes, system
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <cuda.h>
#include <sys/time.h>

// includes, kernels
#include <backprop_cuda_kernel.cu>
#include "backprop.h"

////////////////////////////////////////////////////////////////////////////////

extern "C"
void bpnn_layerforward(float *l1, float *l2, float **conn, int n1, int n2);

extern "C"
void bpnn_output_error(float *delta, float *target, float *output, int nj, float *err);

extern "C"
void bpnn_hidden_error(float *delta_h, int nh, float *delta_o, int no, float **who, float *hidden, float *err);

extern "C" 
void bpnn_adjust_weights(float *delta, int ndelta, float *ly, int nly, float **w, float **oldw);

extern "C"
BPNN *bpnn_create(int n_in, int n_hidden, int n_out);

extern "C"
void bpnn_free(BPNN *net);

extern "C"
void bpnn_initialize(int seed);

extern "C"
int setup(int argc, char** argv);

extern "C"
float **alloc_2d_dbl(int m, int n);

extern "C"
float squash(float x);

double gettime()
{
  struct timeval t;
  gettimeofday(&t,NULL);
  return t.tv_sec+t.tv_usec*1e-6;
}

unsigned int num_threads = 0;
unsigned int num_blocks = 0;


int layer_size = 0;

extern "C"
void bpnn_train_cuda(BPNN *net, float *eo, float *eh)
{
  int in, hid, out;
  float out_err, hid_err;
  int iter; 

  in = net->input_n;
  hid = net->hidden_n;
  out = net->output_n;   
   
#ifdef GPU 
  int m = 0;
  float *input_hidden_cuda;
  float *input_cuda;
  float *partial_sum;
  float *hidden_partial_sum;
  float *hidden_delta_cuda;
  float *input_prev_weights_cuda;
  float sum;
  float *input_weights_one_dim;
  float *input_weights_prev_one_dim;
  num_blocks = in / 16;  
  dim3  grid( 1 , num_blocks);
  dim3  threads(16 , 16);
  
  input_weights_one_dim = (float *) malloc((in + 1)* (hid + 1) * sizeof(float));
  input_weights_prev_one_dim = (float *) malloc((in + 1)* (hid + 1) * sizeof(float));
  partial_sum = (float *) malloc(num_blocks * WIDTH * sizeof(float));
 
  // this preprocessing stage is added to correct the bugs of wrong memcopy using two-dimensional net->inputweights
  for (int k = 0; k <= in; k++) {	
   for (int j = 0; j <= hid; j++) {
     input_weights_one_dim[m] = net->input_weights[k][j];
     input_weights_prev_one_dim[m] = net-> input_prev_weights[k][j];
     m++;
    }
  }
  
  cudaMalloc((void**) &input_cuda, (in + 1) * sizeof(float));
  cudaMalloc((void**) &input_hidden_cuda, (in + 1) * (hid + 1) * sizeof(float));
  cudaMalloc((void**) &hidden_partial_sum, num_blocks * WIDTH * sizeof(float));

  cudaMalloc((void**) &hidden_delta_cuda, (hid + 1) * sizeof(float));
  cudaMalloc((void**) &input_prev_weights_cuda, (in + 1) * (hid + 1) * sizeof(float));
#endif

#ifdef CPU
#ifdef VERBOSE 
  printf("Performing CPU computation\n");
#endif // VERBOSE
  bpnn_layerforward(net->input_units, net->hidden_units,net->input_weights, in, hid);
#endif // CPU

#ifdef GPU
#ifdef VERBOSE 
  printf("Performing GPU computation\n");
  printf("in= %d, hid = %d, numblocks = %d\n", in, hid, num_blocks);
#endif // VERBOSE 
  
  cudaMemcpy(input_cuda, net->input_units, (in + 1) * sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(input_hidden_cuda, input_weights_one_dim, (in + 1) * (hid + 1) * sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(input_prev_weights_cuda, input_weights_prev_one_dim, (in + 1) * (hid + 1) * sizeof(float), cudaMemcpyHostToDevice);

  struct timeval tv1,tv2;

  for( iter = 0; iter < ITER; iter++) {
    gettimeofday( &tv1, NULL);

    my_bpnn_layerforward_CUDA<<< grid, threads >>>(input_cuda, input_hidden_cuda, hidden_partial_sum, in, hid);
   
    cudaThreadSynchronize();
   
/* 
    cudaError_t error = cudaGetLastError();
    if (error != cudaSuccess) {
      printf("bpnn kernel error: %s\n", cudaGetErrorString(error));
      exit(EXIT_FAILURE);
    }
*/
    
    cudaMemcpy(partial_sum, hidden_partial_sum, num_blocks * WIDTH * sizeof(float), cudaMemcpyDeviceToHost);
       
    for (int j = 1; j <= hid; j++) {
      sum = 0.0;
      for (int k = 0; k < num_blocks; k++) {	
	sum += partial_sum[k * hid + j-1] ;
      }
      sum += net->input_weights[0][j];
      net->hidden_units[j] = float(1.0 / (1.0 + exp(-sum)));
    }

    #ifdef VERBOSE 
      int i;
      for( i = 0; i < hid+1; i++) {
	printf("%f\n", net->hidden_units[i]); 
      }
    #endif // VERBOSE 
    #endif // GPU

      bpnn_layerforward(net->hidden_units, net->output_units, net->hidden_weights, hid, out);
      bpnn_output_error(net->output_delta, net->target, net->output_units, out, &out_err);
      bpnn_hidden_error(net->hidden_delta, hid, net->output_delta, out, net->hidden_weights, net->hidden_units, &hid_err);  
      bpnn_adjust_weights(net->output_delta, out, net->hidden_units, hid, net->hidden_weights, net->hidden_prev_weights);

    #ifdef CPU
      bpnn_adjust_weights(net->hidden_delta, hid, net->input_units, in, net->input_weights, net->input_prev_weights);
    #endif // CPU 

    #ifdef GPU

    cudaMemcpy(hidden_delta_cuda, net->hidden_delta, (hid + 1) * sizeof(float), cudaMemcpyHostToDevice);

    my_bpnn_adjust_weights_cuda<<< grid, threads >>>(hidden_delta_cuda, hid, input_cuda, in, input_hidden_cuda, input_prev_weights_cuda);

    cudaThreadSynchronize();

    gettimeofday( &tv2, NULL);
    double runtime = ((tv2.tv_sec*1000.0 + tv2.tv_usec/1000.0)-(tv1.tv_sec*1000.0 + tv1.tv_usec/1000.0));
    printf("Back propagation runtime(1 iteration in milliseconds): %f\n", runtime);
  }

  //cudaMemcpy(net->input_units, input_cuda, (in + 1) * sizeof(float), cudaMemcpyDeviceToHost);
  cudaMemcpy(input_weights_one_dim, input_hidden_cuda, (in + 1) * (hid + 1) * sizeof(float), cudaMemcpyDeviceToHost);
  cudaMemcpy(input_weights_prev_one_dim, input_prev_weights_cuda, (in + 1) * (hid + 1) * sizeof(float), cudaMemcpyDeviceToHost);

#ifdef VERBOSE
  int j;   
  for( i = 0; i <= in; i++) {
    for( j = 0; j <= hid; j++) {
      printf("%f\n", input_weights_one_dim[i*(hid+1)+j]);
    }
    printf("\n"); 
  }

  for( i = 0; i <= in; i++) {
    for( j = 0; j <= hid; j++) {
      printf("%f\n", input_weights_prev_one_dim[i*(hid+1)+j]);
    }
    printf("\n"); 
  }
#endif // VERBOSE

  cudaFree(input_cuda);
  cudaFree(input_hidden_cuda);
  cudaFree(hidden_partial_sum);
  cudaFree(input_prev_weights_cuda);
  cudaFree(hidden_delta_cuda);
  
  free(partial_sum);
  free(input_weights_one_dim);
  free(input_weights_prev_one_dim);
#endif // GPU  
}

void load( BPNN *net)
{
  float *units;
  int nr, i,  k;

  nr = layer_size;
  
  units = net->input_units;

  k = 1;
  for (i = 0; i < nr; i++) {
    units[k] = (float) rand()/RAND_MAX ;
    k++;
  }
}

void backprop_face()
{
  BPNN *net;
  float out_err, hid_err;
  net = bpnn_create(layer_size, 16, 1); // (16, 1 can not be changed)

#ifdef VERBOSE 
  printf("Input layer size : %d\n", layer_size);
#endif

  load(net);

  //entering the training kernel, only one iteration
#ifdef VERBOSE 
  printf("Starting training kernel\n");
#endif

  bpnn_train_cuda(net, &out_err, &hid_err);
  bpnn_free(net);

#ifdef VERBOSE 
  printf("Training done\n");
#endif
}

int setup(int argc, char *argv[])
{
  int seed;
/*
  if( argc != 2){
    fprintf(stderr, "usage: backprop <num of input elements>\n");
    exit(0);
  }
*/
  /* Set layer size to constant so that it's now 'AKS' 
   * to make it fair to compare with the AKS SAC 
   * implementation */
  //layer_size = atoi(argv[1]);
  layer_size = 65536;

  if( layer_size % 16 != 0){
    fprintf(stderr, "The number of input points must be divided by 16\n");
    exit(0);
  }

  seed = 7;   
  bpnn_initialize(seed);
  backprop_face();

  exit(0);
}

////////////////////////////////////////////////////////////////////////////////
// Program main
////////////////////////////////////////////////////////////////////////////////
int main( int argc, char** argv) 
{
  setup(argc, argv);
}


