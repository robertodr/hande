module csr

! Handling of sparse matrices in CSR format.
! This is not intended to be a complete implementation, but rather only include
! procedures as required in HANDE.

! Parallelisation (beyond perhaps OpenMP) is beyond the current scope and not
! all procedures have threading so they can be called from regions already
! parallelised using MPI and/or OpenMP.

! We use the abbreviations nrow and nnz to stand for the number of rows of and
! the number of non-zero elements of a matrix, respectively.

use const, only: p

implicit none

! real(p) matrix
type csrp_t
    ! For matrices which will use the symmetric routines, this stores the
    ! non-zero elements of upper *or* lower triangle of matrix.
    ! For general matrices, all of the non-zero elements are stored.
    real(p), allocatable :: mat(:) ! (nnz)
    ! Column index of values stored in mat.
    ! If M_{ij} is stored in mat(k), then col_ind(k) = j.
    integer, allocatable :: col_ind(:) ! (nnz)
    ! row_ptr(i) gives the location in mat of the first non-zero element in row
    ! i, i.e. if mat(k) = M_{ij}, then row_ptr(i) <= k < row_ptr(i+1).  By
    ! convention, row_ptr(nrow+1) = nnz+1.
    integer, allocatable :: row_ptr(:) ! (nrow+1)
    ! WARNING: if the matrix is symmetric, it is assumed that the programmer
    ! only stores the uppper *or* lower triangle of the matrix.
    logical :: symmetric = .false.
end type csrp_t

contains

    subroutine init_csrp(spm, nrow, nnz, symmetric)

        ! Initialise a real(p) sparse symmetrix matrix in csr format.

        ! In:
        !    nrow: number of rows in matrix.
        !    nnz: number of non-zero elements in upper/lower triangle of matrix.
        !    symmetric: (optional, default: false).
        ! Out:
        !    spm: csrp_t object with components correctly allocated and
        !         row_ptr(nrow+1) set to nnz+1.

        use checking, only: check_allocate

        type(csrp_t), intent(out) :: spm
        integer, intent(in) :: nrow, nnz
        logical, intent(in), optional :: symmetric

        integer :: ierr

        allocate(spm%mat(nnz), stat=ierr)
        call check_allocate('spm%mat', nnz, ierr)
        allocate(spm%col_ind(nnz), stat=ierr)
        call check_allocate('spm%col_ind', nnz, ierr)
        allocate(spm%row_ptr(nrow+1), stat=ierr)
        call check_allocate('spm%row_ptr', nrow+1, ierr)
        spm%row_ptr(nrow+1) = nnz+1

        if (present(symmetric)) spm%symmetric = symmetric

    end subroutine init_csrp

    subroutine end_csrp(spm)

        ! Deallocate components of a real(p) sparse matrix in csr format.

        ! In/Out:
        !    spm: csrp_t object with all components deallocated on exit.

        use checking, only: check_deallocate

        type(csrp_t), intent(inout) :: spm

        integer :: ierr

        deallocate(spm%mat, stat=ierr)
        call check_deallocate('spm%mat', ierr)
        deallocate(spm%col_ind, stat=ierr)
        call check_deallocate('spm%col_ind', ierr)
        deallocate(spm%row_ptr, stat=ierr)
        call check_deallocate('spm%row_ptr', ierr)

    end subroutine end_csrp

    ! [review] - JSS: The name change (and similarly for the following routines) are not so helpful.
    ! [review] - JSS: It is no longer clear that they involve matrix-vector multiplication.
    ! [review] - JSS: It was using LAPACK abbreviations, SYMV == SYmmetric Matrix Vector.
    ! [review] - JSS: Maybe this was only clear to me though...
    subroutine csrpsymv(spm, x, y)

        ! Calculate y = m*x, where m is a sparse symmetric matrix and x and
        ! y are dense vectors.

        ! In:
        !   spm: sparse symmetric matrix (real(p) in csr format.  See
        !        module-level notes about storage format.
        !   x: dense vector.  Number of elements must be at least the number of
        !      rows in spm.
        ! Out:
        !   y: dense vector.  Holds m*x on exit..  Number of elements must be at
        !      least the number of rows in spm, with all additional elements set to
        !      0.

        ! WARNING: if the matrix is symmetric, it is assumed that the programmer
        ! only stores the uppper *or* lower triangle of the matrix.

        use errors, only: stop_all

        type(csrp_t), intent(in) :: spm
        real(p), intent(in) :: x(:)
        real(p), intent(out) :: y(:)

        integer :: irow, icol, iz
        real(p) :: rowx

        ! [review] - JSS: procedure name in stop_all should also be changed.
        if (.not.spm%symmetric) call stop_all('csrpsymv', 'Sparse matrix not symmetric.')
        
        y = 0.0_p
        ! Avoid overhead of creating thread pool.
        ! However, by not just doing "!$omp parallel do", we must be *very*
        ! careful when accessing or updating any shared value.
        !$omp parallel
        do irow = 1, size(spm%row_ptr)-1
            !$omp master
            rowx = 0.0_p
            !$omp end master
            !$omp barrier
            ! OpenMP chunk size determined completely empirically from a single
            ! test.  Please feel free to improve...
            !$omp do private(icol) reduction(+:rowx) schedule(dynamic, 200)
            do iz = spm%row_ptr(irow), spm%row_ptr(irow+1)-1
                icol = spm%col_ind(iz)
                y(icol) = y(icol) + spm%mat(iz)*x(irow)
                if (icol /= irow) rowx = rowx + spm%mat(iz)*x(icol)
            end do
            !$omp end do
            !$omp master
            y(irow) = y(irow) + rowx
            !$omp end master
        end do
        !$omp end parallel

    end subroutine csrpsymv

    subroutine csrpgemv(spm, x, y)

        ! Calculate y = m*x, where m is a sparse matrix and x and y are dense
        ! vectors.

        ! In:
        !   spm: sparse matrix (real(p) in csr format. See module-level notes
        !        about storage format.
        !   x: dense vector.  Number of elements must be at least the number of
        !      columns in spm.
        ! Out:
        !   y: dense vector.  Holds m*x on exit..  Number of elements must be at
        !      least the number of rows in spm, with all additional elements set to
        !      0.

        use errors, only: stop_all

        type(csrp_t), intent(in) :: spm
        real(p), intent(in) :: x(:)
        real(p), intent(out) :: y(:)

        integer :: irow, icol, iz

        ! This routine should not be used for symmetric matrices where only the
        ! upper or lower halves of the matrix are stored.
        ! [review] - JSS: procedure name in stop_all.
        if (spm%symmetric) call stop_all('csrpgemv', 'Sparse matrix is symmetric.')
        
        y = 0.0_p
        do irow = 1, size(spm%row_ptr)-1
            do iz = spm%row_ptr(irow), spm%row_ptr(irow+1)-1
                icol = spm%col_ind(iz)
                y(irow) = y(irow) + spm%mat(iz)*x(icol)
            end do
        end do

    end subroutine csrpgemv

    ! [review] - JSS: I think it's easiest to parse if the argument list goes inputs,
    ! [review] - JSS: outputs, optional inputs, optional outputs.  (Also matches rest of code...)
    ! [review] - JSS: Sometimes it makes sense to group connected inputs and outputs together, but I still find it easier if inputs
    ! [review] - JSS: come first within the group...perhaps I'm just picky though!
    subroutine csrpgemv_single_row(spm, x, irow, y_irow)

        ! Calculate a single value in the vector y = m*x, where m is a sparse
        ! matrix and x and y are dense vectors.

        ! In:
        !   spm: sparse matrix (real(p) in csr format. See module-level notes
        !        about storage format.
        !   x: dense vector.  Number of elements must be at least the number of
        !      columns in spm.
        !   irow: The index of the row of the Hamiltonian to multiply with.
        ! Out:
        !   y_irow: Holds \sum_j m_{irow,j}*x_j on exit.

        use errors, only: stop_all

        type(csrp_t), intent(in) :: spm
        real(p), intent(in) :: x(:)
        integer, intent(in) :: irow
        real(p), intent(out) :: y_irow

        integer :: icol, iz

        y_irow = 0.0_p
        do iz = spm%row_ptr(irow), spm%row_ptr(irow+1)-1
            icol = spm%col_ind(iz)
            y_irow = y_irow + spm%mat(iz)*x(icol)
        end do

    end subroutine csrpgemv_single_row

end module csr
