#include <iostream>
#include <iomanip>
#include <math.h>
#include <helper_cuda.h>
#include <complex>
#include <cufft.h>

#include "spread.h"
#include "memtransfer.h"
#include "deconvolve.h"
#include "cufinufft.h"
#include "finufft/utils.h"
#include "finufft/common.h"

using namespace std;

int cufinufft2d1_plan(int M, FLT* h_kx, FLT* h_ky, CPX* h_c, int ms, int mt, CPX* h_fk, 
		int iflag, spread_opts opts, cufinufft_plan *d_plan)
{
	cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);

	int ier;
	//ier=setup_cuspreader(opts,eps,upsampfac);
	int nf1 = (int) opts.upsampfac*ms;
	int nf2 = (int) opts.upsampfac*mt;
	int fftsign = (iflag>=0) ? 1 : -1;
	
	d_plan->ms = ms;
	d_plan->mt = mt;
	d_plan->nf1 = nf1;
	d_plan->nf2 = nf2;
	d_plan->h_kx = h_kx;
	d_plan->h_ky = h_ky;
	d_plan->h_c = h_c;
	d_plan->h_fk = h_fk;
	d_plan->M = M;
	d_plan->iflag = fftsign; 
#ifdef INFO
	printf("[info  ] 2d1: (ms,mt)=(%d,%d) (nf1, nf2)=(%d,%d) nj=%d\n", ms, mt, d_plan->nf1, d_plan->nf2, d_plan->M);
#endif

	// this may move to gpu
	CNTime timer; timer.start();
	FLT *fwkerhalf1 = (FLT*)malloc(sizeof(FLT)*(nf1/2+1));
	FLT *fwkerhalf2 = (FLT*)malloc(sizeof(FLT)*(nf2/2+1));
	onedim_fseries_kernel(nf1, fwkerhalf1, opts);
	onedim_fseries_kernel(nf2, fwkerhalf2, opts);
	d_plan->h_fwkerhalf1 = fwkerhalf1;
	d_plan->h_fwkerhalf2 = fwkerhalf2;
#ifdef TIME
	printf("[time  ] \tkernel fser (ns=%d):\t %.3g s\n", opts.nspread,timer.elapsedsec());
#endif

	cudaEventRecord(start);
	ier = allocgpumemory(opts, d_plan);
#ifdef TIME
	float milliseconds = 0;
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tAllocate GPU memory\t %.3g s\n", milliseconds/1000);
#endif
	cudaEventRecord(start);
	cufftHandle fftplan;
	int ndata=1;
	int n[] = {nf2, nf1};
	int inembed[] = {nf2, d_plan->fw_width};
	cufftPlanMany(&fftplan,2,n,inembed,1,inembed[0]*inembed[1],inembed,1,inembed[0]*inembed[1],
			CUFFT_TYPE,ndata);
	d_plan->fftplan = fftplan;
#ifdef TIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tCUFFT Plan\t\t %.3g s\n", milliseconds/1000);
#endif
	return ier;
}

int cufinufft2d1_exec(spread_opts opts, cufinufft_plan *d_plan)
{
	opts.spread_direction=1;
	cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);

	cudaEventRecord(start);
	if(opts.pirange){
		for(int i=0; i<d_plan->M; i++){
			d_plan->h_kx[i]=RESCALE(d_plan->h_kx[i], d_plan->nf1, opts.pirange);
			d_plan->h_ky[i]=RESCALE(d_plan->h_ky[i], d_plan->nf2, opts.pirange);
		}
	}	

	// Copy memory to device
	int ier = copycpumem_to_gpumem(opts, d_plan);
#ifdef TIME
	float milliseconds = 0;
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tCopy memory HtoD\t %.3g s\n", milliseconds/1000);
#endif
	// Step 1: Spread
        cudaEventRecord(start);
        ier = cuspread2d(opts, d_plan);
        if(ier != 0 ){
                printf("error: cuspread2d, method(%d)\n", opts.method);
                return 0;
        }
#ifdef TIME
        cudaEventRecord(stop);
        cudaEventSynchronize(stop);
        cudaEventElapsedTime(&milliseconds, start, stop);
        printf("[time  ] \tSpread\t\t\t %.3g s\n", milliseconds/1000);
#endif
	// Step 2: FFT
	cudaEventRecord(start);
	CUFFT_EX(d_plan->fftplan, d_plan->fw, d_plan->fw, d_plan->iflag);
#ifdef TIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tCUFFT Exec\t\t %.3g s\n", milliseconds/1000);
#endif

	// Step 3: deconvolve and shuffle
	cudaEventRecord(start);
	cudeconvolve2d(opts,d_plan);
#ifdef TIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tDeconvolve\t\t %.3g s\n", milliseconds/1000);
#endif
	cudaEventRecord(start);
	ier = copygpumem_to_cpumem_fk(d_plan);
#ifdef TIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tCopy memory DtoH\t %.3g s\n", milliseconds/1000);
#endif
	return ier;
}

int cufinufft2d2_exec(spread_opts opts, cufinufft_plan *d_plan)
{
	opts.spread_direction=2;

	cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);

	cudaEventRecord(start);
	if(opts.pirange){
		for(int i=0; i<d_plan->M; i++){
			d_plan->h_kx[i]=RESCALE(d_plan->h_kx[i], d_plan->nf1, opts.pirange);
			d_plan->h_ky[i]=RESCALE(d_plan->h_ky[i], d_plan->nf2, opts.pirange);
		}
	}	

	// Copy memory to device
	int ier = copycpumem_to_gpumem(opts, d_plan);
#ifdef TIME
	float milliseconds = 0;
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tCopy memory HtoD\t %.3g s\n", milliseconds/1000);
#endif
	// Step 1: amplify Fourier coeffs fk and copy into upsampled array fw
	cudaEventRecord(start);
	cudeconvolve2d(opts,d_plan);
#ifdef TIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tAmplify & Copy fktofw\t %.3g s\n", milliseconds/1000);
#endif
	// Step 2: FFT
	cudaEventRecord(start);
	CUFFT_EX(d_plan->fftplan, d_plan->fw, d_plan->fw, d_plan->iflag);
#ifdef TIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tCUFFT Exec\t\t %.3g s\n", milliseconds/1000);
#endif

	// Step 3: deconvolve and shuffle
        cudaEventRecord(start);
        ier = cuinterp2d(opts, d_plan);
        if(ier != 0 ){
                printf("error: cuinterp2d, method(%d)\n", opts.method);
                return 0;
        }
#ifdef TIME
        cudaEventRecord(stop);
        cudaEventSynchronize(stop);
        cudaEventElapsedTime(&milliseconds, start, stop);
        printf("[time  ] \tUnspread\t\t %.3g s\n", milliseconds/1000);
#endif

	cudaEventRecord(start);
	ier = copygpumem_to_cpumem_c(d_plan);
#ifdef TIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tCopy memory DtoH\t %.3g s\n", milliseconds/1000);
#endif
	return ier;
}

int cufinufft2d1_destroy(spread_opts opts, cufinufft_plan *d_plan)
{
	cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);

	cudaEventRecord(start);
        cufftDestroy(d_plan->fftplan);
        free_gpumemory(opts, d_plan);
	free(d_plan->h_fwkerhalf1);
	free(d_plan->h_fwkerhalf2);
#ifdef TIME
	float milliseconds = 0;
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tFree gpu memory\t\t %.3g s\n", milliseconds/1000);
#endif
	return 0;
}
