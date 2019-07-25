#include <iostream>
#include <iomanip>
#include <math.h>
#include <helper_cuda.h>
#include <complex>

#include "../src/spreadinterp.h"
#include "../src/cufinufft.h"
#include "../finufft/utils.h"

using namespace std;

int main(int argc, char* argv[])
{
	int N1, N2, M, N;
	if (argc<4) {
		fprintf(stderr,"Usage: cufinufft2d1_test [method [N1 N2 [M [tol]]]]\n");
		fprintf(stderr,"Details --\n");
		fprintf(stderr,"method 1: nupts driven\n");
		fprintf(stderr,"method 2: sub-problem\n");
		fprintf(stderr,"method 3: sub-problem with paul's idea\n");
		return 1;
	}  
	double w;
	int method;
	sscanf(argv[1],"%d",&method);
	sscanf(argv[2],"%lf",&w); N1 = (int)w;  // so can read 1e6 right!
	sscanf(argv[3],"%lf",&w); N2 = (int)w;  // so can read 1e6 right!
	N = N1*N2;
	M = N1*N2;// let density always be 1
	if(argc>4){
		sscanf(argv[4],"%lf",&w); M  = (int)w;  // so can read 1e6 right!
	}

	FLT tol=1e-6;
	if(argc>5){
		sscanf(argv[5],"%lf",&w); tol  = (FLT)w;  // so can read 1e6 right!
	}
	int iflag=1;


	cout<<scientific<<setprecision(3);
	int ier;


	FLT *x, *y;
	CPX *c, *fk;
	cudaMallocHost(&x, M*sizeof(FLT));
	cudaMallocHost(&y, M*sizeof(FLT));
	cudaMallocHost(&c, M*sizeof(CPX));
	cudaMallocHost(&fk,N1*N2*sizeof(CPX));

	// Making data
	for (int i = 0; i < M; i++) {
		x[i] = M_PI*randm11();// x in [-pi,pi)
		y[i] = M_PI*randm11();
		c[i].real() = randm11();
		c[i].imag() = randm11();
	}

	cudaEvent_t start, stop;
	float milliseconds = 0;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);

	/*warm up gpu*/
	cudaEventRecord(start);
	char *a;
	checkCudaErrors(cudaMalloc(&a,1));
#ifdef TIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tWarm up GPU \t\t %.3g s\n", milliseconds/1000);
#endif

	cufinufft_plan dplan;
	int dim = 2;

	ier=cufinufft_default_opts(type1, dim, dplan.opts);
	dplan.opts.gpu_method=method;

	int nmodes[3];
	int ntransf = 1;
	int ntransfcufftplan = 1;
	nmodes[0] = N1;
	nmodes[1] = N2;
	nmodes[2] = 1;
	cudaEventRecord(start);
	ier=cufinufft_makeplan(type1, dim, nmodes, iflag, ntransf, tol, 
		ntransfcufftplan, &dplan);
	if (ier!=0){
		printf("err: cufinufft2d_plan\n");
	}
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] cufinufft plan:\t\t %.3g s\n", milliseconds/1000);

	cudaEventRecord(start);
	ier=cufinufft_setNUpts(M, x, y, NULL, 0, NULL, NULL, NULL, &dplan);
	if (ier!=0){
		printf("err: cufinufft_setNUpts\n");
	}
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] cufinufft setNUpts:\t\t %.3g s\n", milliseconds/1000);

	cudaEventRecord(start);
	ier=cufinufft_exec(c, fk, &dplan);
	if (ier!=0){
		printf("err: cufinufft2d1_exec\n");
	}
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] cufinufft exec:\t\t %.3g s\n", milliseconds/1000);

	cudaEventRecord(start);
	ier=cufinufft_destroy(&dplan);
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] cufinufft destroy:\t\t %.3g s\n", milliseconds/1000);

	int nt1 = (int)(0.37*N1), nt2 = (int)(0.26*N2);  // choose some mode index to check
	CPX Ft = CPX(0,0), J = IMA*(FLT)iflag;
	for (BIGINT j=0; j<M; ++j)
		Ft += c[j] * exp(J*(nt1*x[j]+nt2*y[j]));   // crude direct
	int it = N1/2+nt1 + N1*(N2/2+nt2);   // index in complex F as 1d array
	printf("[gpu   ] one mode: abs err in F[%ld,%ld] is %.3g\n",(int)nt1,(int)nt2,abs(Ft-fk[it]));
	printf("[gpu   ] one mode: rel err in F[%ld,%ld] is %.3g\n",(int)nt1,(int)nt2,abs(Ft-fk[it])/infnorm(N,fk));
#if 0
	cout<<"[result-input]"<<endl;
	for(int j=0; j<nf2; j++){
		//        if( j % opts.gpu_binsizey == 0)
		//                printf("\n");
		for (int i=0; i<nf1; i++){
			//                if( i % opts.gpu_binsizex == 0 && i!=0)
			//                        printf(" |");
			printf(" (%2.3g,%2.3g)",fw[i+j*nf1].real(),fw[i+j*nf1].imag() );
		}
		cout<<endl;
	}
#endif	
	cudaFreeHost(x);
	cudaFreeHost(y);
	cudaFreeHost(c);
	cudaFreeHost(fk);
	return 0;
}