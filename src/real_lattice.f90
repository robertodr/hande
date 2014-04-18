module real_lattice

! Real space formulation of the Hubbard model.

use const

implicit none

! The kinetic term is constant in the real space formulation:
! only the connectivity of the lattice matters.
! tmat(:,i) is a bit string.  The j-th bit corresponding to a basis function
! (as given by bit_lookup) is set if i and j are connected.
! We need to distinguish between connections within the cell and those due to
! periodic boundaries.  We do this by the following strategy:
!   a) j>i.
!          If the j-th bit is set then i and j are connected within the crystal
!          cell.
!   b) j<=i.
!          If the i-th bit of tmat(:,j) is set, then i and j are connected due
!          to periodic boundary conditions.
! This may seem like a somewhat arbitrary choice, but it enables for the
! correct evaluation of the kinetic energy using bit operations.
! Further it enables us to pick up cases such as the 2x2 (non-tilted) system,
! where a site is connected to a different site and that site's periodic image.
integer(i0), allocatable :: tmat(:,:) ! (basis_length, nbasis)

! Orbitals i and j are connected if the j-th bit of connected_orbs(:,i) is
! set.  This is a bit like tmat but without a bit set for a site being its own
! periodic image.  This is useful in FCIQMC for generating random
! excitations.
integer(i0), allocatable :: connected_orbs(:,:) ! (basis_length, nbasis)

! connected_sites(0,i) contains the number of unique sites connected to i.
! connected_sites(1:,i) contains the list of sites connected to site i (ie is the
! decoded/non-bit list form of connected_orbs).
! If connected_orbs(j,i) is 0 then it means there are fewer than 2*ndim unique sites
! that are connected to i that are not a periodic image of i (or connected to
! i both directly and via periodic boundary conditions).
! For the triangular lattice, there are 3*ndim bonds, and ndim must equal 2,
! so each site is connected to 6.
integer, allocatable :: connected_sites(:,:) ! (0:2ndim, nbasis) or (0:3dim, nbasis)

! next_nearest_orbs(i,j) gives the number of paths by which sites i and j are
! are next nearest neighbors. For example, on a square lattice in the
! Heisenberg model, if we consider a spin, we can get to a next-nearest
! neighbor spin by going one right then one up, or to the same spin by going
! one up and then one right - there are two different paths, so the correpsonding
! value of next_nearest_orbs would be 2 for these spins. This is an important
! number to know when calculating the thermal energy squared in DMQMC.
! If two spins are not next-nearest neighbors by any path then this quantity is 0.
! By next nearest neighbors, it is meant sites which can be joined by exactly two
! bonds - any notion one may have of where the spins are located spatially is unimportant.
integer(i0), allocatable :: next_nearest_orbs(:,:) ! (nbasis, nbasis)

! True if any site is its own periodic image.
! This is the case if one dimension (or more) has only one site per crystalisystem
! cell.  If so then the an orbital can incur a kinetic interaction with itself.
! This is the only way that the integral < i | T | i >, where i is a basis
! function centred on a lattice site, can be non-zero.
logical :: t_self_images

! True if we are actually only modelling a finite system (e.g. a H_2 molecule)
! False if we are modelling an infinite lattice
! The code is set up to model inifinite lattices by default, however in order
! to model only a finite "cluster" of sites, all one need do is set the
! connection matrix elements corresponding to connections accross cell
! boundaries (i.e. periodic boundary conditions) to 0
logical :: finite_cluster = .false. ! default to infinite crystals


contains

    subroutine init_real_space(sys)

        ! Initialise real space Hubbard model and Heisenberg model: find and store
        ! the matrix elements < i | T | j > where i and j are real space basis functions.

        ! In/Out:
        !    sys: system to be studied.  On output the symmetry components are set.

        use basis, only: nbasis, bit_lookup, basis_lookup, basis_length, basis_fns, set_orb
        use calc, only: doing_dmqmc_calc, dmqmc_energy_squared
        use determinants, only: decode_det
        use system
        use bit_utils
        use checking, only: check_allocate
        use errors, only: stop_all
        use parallel, only: parent

        type(sys_t), intent(inout) :: sys
        integer :: i, j, k, ierr, pos, ind, ivec, v, isystem
        integer :: r(sys%lattice%ndim)
        logical :: diag_connection

        sys%nsym = 1
        sys%sym0 = 1
        sys%sym_max = 1
        sys%nsym_tot = 1
        sys%sym0_tot = 1
        sys%sym_max_tot = 1

        associate(sl=>sys%lattice)

            t_self_images = any(abs(sl%box_length-1.0_p) < depsilon)

            allocate(tmat(basis_length,nbasis), stat=ierr)
            call check_allocate('tmat',basis_length*nbasis,ierr)
            allocate(connected_orbs(basis_length,nbasis), stat=ierr)
            call check_allocate('connected_orbs',basis_length*nbasis,ierr)
            allocate(sl%lvecs(sl%ndim,3**sl%ndim))
            call check_allocate('sl%lvecs',sl%ndim*(3**sl%ndim),ierr)
            if (sl%triangular_lattice) then
                allocate(connected_sites(0:3*sl%ndim,nbasis), stat=ierr)
                call check_allocate('connected_sites', size(connected_sites), ierr)
            else
                allocate(connected_sites(0:2*sl%ndim,nbasis), stat=ierr)
                call check_allocate('connected_sites', size(connected_sites), ierr)
            end if
            if (doing_dmqmc_calc(dmqmc_energy_squared)) then
                allocate(next_nearest_orbs(nbasis,nbasis), stat=ierr)
                call check_allocate('next_nearest_orbs',nbasis*nbasis,ierr)
            end if

            tmat = 0_i0
            connected_orbs = 0_i0

            ! For the Hubbard model, each orbital can have spin up or down, so
            ! basis_fns(i) refers to alternating alpha and beta orbitals.
            ! In the do loop we therefore loop over every *second* orbital (because
            ! spin must be the same for orbitals to be connected in this case).
            ! For Heisenberg and Chung--Landau models, we just want to loop over
            ! every component of basis_fns, so we set isystem = 1
            select case(sys%system)
            case(heisenberg, chung_landau)
                isystem = 1
            case default
                isystem = 2
            end select


            ! Form all sl%lattice vectors
            select case(sl%ndim)
            case(1)
                do i = -1, 1
                    sl%lvecs(:,i+2) = i*sl%lattice(:,1)
                end do
            case(2)
                do i = -1, 1
                    do j = -1, 1
                        sl%lvecs(:,j+2+3*(i+1)) = i*sl%lattice(:,1) + j*sl%lattice(:,2)
                    end do
                end do
            case(3)
                do i = -1, 1
                    do j = -1, 1
                        do k = -1, 1
                            sl%lvecs(:,k+2+3*(j+1)+9*(i+1)) = i*sl%lattice(:,1) + j*sl%lattice(:,2) + k*sl%lattice(:,3)
                        end do
                    end do
                end do
            end select

            ! Construct how the sl%lattice is connected.
            diag_connection = .false. ! For sl%ndim /= 2.
            do i = 1, nbasis-(isystem-1), isystem
                do j = i, nbasis-(isystem-1), isystem
                    ! Loop only over one spin: the other spin is identical so can be
                    ! filled in automatically.
                    ! All matrix elements between different spins are zero
                    ! Allow j=i in case i is its own periodic image.
                    r = basis_fns(i)%l - basis_fns(j)%l
                    do ivec = 1, 3**sl%ndim
                        ! For the triangular sl%lattice, there are extra diagonal bonds between pairs
                        ! of sites which obey this condition.
                        if (sl%ndim == 2) then
                            diag_connection = all((r-sl%lvecs(:,ivec)) == (/1,1/)) .or. &
                                              all((r-sl%lvecs(:,ivec)) == (/-1,-1/))
                        end if
                        if (sum(abs(r-sl%lvecs(:,ivec))) == 1 .or. &
                            (sl%triangular_lattice .and. diag_connection)) then
                            ! i and j are on sites which are nearest neighbours
                            if (all(sl%lvecs(:,ivec) == 0)) then
                                ! Nearest neighbours within unit cell.
                                call set_orb(tmat(:,i),j)
                                if (isystem == 2) call set_orb(tmat(:,i+1),j+1)
                            else if (.not. finite_cluster) then ! if we want inf. sl%lattice
                                ! Nearest neighbours due to periodic boundaries.
                                call set_orb(tmat(:,j),i)
                                if (isystem == 2) call set_orb(tmat(:,j+1),i+1)
                                ! else we just want connections to other cells to
                                ! stay as 0
                            end if

                            ! If we only want a discrete molecule and the sl%lattice
                            ! vector connecting the 2 sites is the 0-vector then the
                            ! 2 sites are connected in a unit cell and thus are
                            ! actually connected. (If they "connect" across cell
                            ! boundaries then they are not connected for a single
                            ! molecule).
                            if ( (finite_cluster .and. all(sl%lvecs(:,ivec) == 0)) .or. &
                                 .not. finite_cluster) then
                                if (i /= j) then
                                    ! connected_orbs does not contain self-connections
                                    ! due to the periodic boundary conditions.
                                    call set_orb(connected_orbs(:,i),j)
                                    if (isystem == 2) call set_orb(connected_orbs(:,i+1),j+1)
                                    call set_orb(connected_orbs(:,j),i)
                                    if (isystem == 2) call set_orb(connected_orbs(:,j+1),i+1)
                                end if
                            end if
                        end if

                    end do
                end do
            end do

        end associate

        if (allocated(next_nearest_orbs)) call create_next_nearest_orbs()

        ! Decode connected_orbs to store list of connections.
        connected_sites = 0
        do i = 1, nbasis
            v = 0
            do ind = 1, basis_length
                do pos = 0, i0_end
                    if (btest(connected_orbs(ind,i), pos)) then
                        v = v + 1
                        connected_sites(v, i) = basis_lookup(pos, ind)
                    end if
                end do
            end do
            connected_sites(0,i) = v
        end do

    end subroutine init_real_space

    subroutine end_real_space()

        ! Clean up real_lattice specific allocations.

        use checking, only: check_deallocate

        integer :: ierr

        if (allocated(tmat)) then
            deallocate(tmat, stat=ierr)
            call check_deallocate('tmat',ierr)
        end if
        if (allocated(connected_orbs)) then
            deallocate(connected_orbs, stat=ierr)
            call check_deallocate('connected_orbs',ierr)
        end if
        if (allocated(connected_sites)) then
            deallocate(connected_sites, stat=ierr)
            call check_deallocate('connected_sites',ierr)
        end if

    end subroutine end_real_space

    elemental function get_one_e_int_real(sys, i, j) result(one_e_int)

        ! In:
        !    sys: system being studied.
        !    i: index of a real-space basis function.
        !    j: index of a real-space basis function.
        ! Returns:
        !    <phi1 | T | phi2> where T is the kinetic energy operator.

        use basis, only: basis_fns, bit_lookup
        use system, only: sys_t

        real(p) :: one_e_int
        type(sys_t), intent(in) :: sys
        Integer, intent(in) ::  i,j
        integer :: ind, pos

        one_e_int = 0.0_p

        ! Need to check if i and j are on sites which are nearest neighbours
        ! either directly or due to periodic boundary conditions.
        pos = bit_lookup(1,j)
        ind = bit_lookup(2,j)
        ! Test if i <-> j.  If so there's a kinetic interaction.
        if (btest(tmat(ind,i),pos)) one_e_int = one_e_int - sys%hubbard%t
        pos = bit_lookup(1,i)
        ind = bit_lookup(2,i)
        ! Test if i <-> j.  If so there's a kinetic interaction.
        if (btest(tmat(ind,j),pos)) one_e_int = one_e_int - sys%hubbard%t

    end function get_one_e_int_real

    pure function get_coulomb_matel_real(sys, f) result(umatel)

        ! In:
        !    sys: system being studied.
        !    f(basis_length): bit string representation of the Slater
        !        determinant, D.
        ! Returns:
        !    The matrix element < D | U | D >
        !    Note < D1 | U | D2 > = 0 if D1/=D2 within the real space
        !    formulation of the Hubbard model.

        use basis
        use system, only: sys_t
        use bit_utils, only: count_set_bits
        use determinants, only: beta_mask, separate_strings

        real(p) :: umatel
        type(sys_t), intent(in) :: sys
        integer(i0), intent(in) :: f(basis_length)
        integer :: i
        integer(i0) :: b

        ! < D | U | D > = U*number of doubly occupied sites.
        if (separate_strings) then
            ! Just need to AND the alpha string with the beta string.
            umatel = sum(count_set_bits(iand(f(:basis_length/2),f(basis_length/2+1:))))
        else
            ! 1. Find the bit string representing the occupied beta orbitals.
            ! 2. Right shift it by one place.  The beta orbitals now line up with
            !    alpha orbitals.
            ! 3. AND the shifted beta bit string with the original bit string
            !    representing the list of occupied orbitals in the determinant.
            ! 4. The non-zero bits represent a sites which have both alpha and beta
            !    orbitals occupied.
            ! 5. Hence < D | U | D >.
            umatel = 0.0_p
            do i = 1, basis_length
                b = iand(f(i), beta_mask)
                umatel = umatel + count_set_bits(iand(f(i), ishft(b,-1)))
            end do
        end if
        umatel = sys%hubbard%u*umatel

    end function get_coulomb_matel_real

    subroutine create_next_nearest_orbs()

        use basis, only: basis_length, nbasis, bit_lookup, basis_fns
        use parallel

        integer :: ibasis, jbasis, kbasis
        integer :: bit_position, bit_element

        next_nearest_orbs = 0_i0

        do ibasis = 1, nbasis
            do jbasis = 1, nbasis
                bit_position = bit_lookup(1,jbasis)
                bit_element = bit_lookup(2,jbasis)
                if (btest(connected_orbs(bit_element,ibasis),bit_position)) then
                    do kbasis = 1, nbasis
                        bit_position = bit_lookup(1,kbasis)
                        bit_element = bit_lookup(2,kbasis)
                        if (btest(connected_orbs(bit_element,jbasis),bit_position)) then
                            next_nearest_orbs(ibasis,kbasis) = next_nearest_orbs(ibasis,kbasis)+1
                        end if
                    end do
                end if
            end do
            next_nearest_orbs(ibasis,ibasis) = 0_i0
        end do

    end subroutine create_next_nearest_orbs

    subroutine find_translational_symmetry_vecs(sys, sym_vecs, nsym)

        ! This routine will find all symmetry vectors for the lattice provided
        ! and return them in sym_vecs.

        ! In:
        !     sys: system being studied.
        ! In/Out:
        !     sym_vecs: An array which on output will hold all translational
        !         symmetry vectors. Should be deallocated on input.
        ! Out:
        !     nsym: The total number of symmetry vectors.

        use checking, only: check_allocate
        use system, only: sys_t

        type(sys_t), intent(in) :: sys
        real(p), allocatable, intent(inout) :: sym_vecs(:,:)
        integer, intent(out) :: nsym
        integer :: i, j, k, l, ierr
        integer :: nvecs(3)
        real(p) :: v(sys%lattice%ndim), test_vec(sys%lattice%ndim)
        integer :: scale_fac

        ! The maximum number of translational symmetry vectors is nsites (for
        ! the case of a non-tilted lattice), so allocate this much storage.
        allocate(sym_vecs(sys%lattice%ndim,sys%lattice%nsites),stat=ierr)
        call check_allocate('sym_vecs',sys%lattice%ndim*sys%lattice%nsites,ierr)
        sym_vecs = 0

        ! The number of symmetry vectors in each direction.
        nvecs = 0
        ! The total number of symmetry vectors.
        nsym = 0

        do i = 1, sys%lattice%ndim
            scale_fac = maxval(abs(sys%lattice%lattice(:,i)))
            v = real(sys%lattice%lattice(:,i),p)/real(scale_fac,p)

            do j = 1, scale_fac-1
                test_vec = v*j
                ! If test_vec has all integer components.
                if (all(.not. (abs(test_vec-real(nint(test_vec),p)) > 0.0_p) )) then
                    ! If this condition is obeyed then this is a symmetry vector,
                    ! so store it.
                    nvecs(i) = nvecs(i) + 1
                    nsym = nsym + 1
                    sym_vecs(:,nsym) = test_vec
                end if
            end do
        end do

        ! Next, add all combinations of the above generated vectors to form a closed group.

        ! Add all pairs of the above vectors.
        do i = 1, nvecs(1)
            do j = nvecs(1)+1, sum(nvecs)
                nsym = nsym + 1
                sym_vecs(:,nsym) = sym_vecs(:,i)+sym_vecs(:,j)
            end do
        end do
        do i = nvecs(1)+1, nvecs(1)+nvecs(2)
            do j = nvecs(1)+nvecs(2)+1, sum(nvecs)
                nsym = nsym + 1
                sym_vecs(:,nsym) = sym_vecs(:,i)+sym_vecs(:,j)
            end do
        end do

        ! Add all triples of the above vectors.
        do i = 1, nvecs(1)
            do j = nvecs(1)+1, nvecs(1)+nvecs(2)
                do k = nvecs(1)+nvecs(2)+1, sum(nvecs)
                    nsym = nsym + 1
                    sym_vecs(:,nsym) = sym_vecs(:,i)+sym_vecs(:,j)+sym_vecs(:,k)
                end do
            end do
        end do

        ! Include the identity transformation vector in the first slot.
        sym_vecs(:,2:nsym+1) = sym_vecs(:,1:nsym)
        sym_vecs(:,1) = 0
        nsym = nsym + 1

    end subroutine find_translational_symmetry_vecs

    subroutine map_vec_to_cell(ndim, lvecs, r)

        ! Map a vector, r, outside from outside to inside the simulation cell.
        ! This subroutine assumes that the site specified by r is outside the cell
        ! by no more than one lattice vector, along each lattice vector.

        ! In:
        !    ndim: dimensionality of the lattice.
        !    lvecs: all 3**ndim possible lattice vectors in the nearest 'shell'
        !       (ie all integer combinations from -1 to 1 for each lattice vector).
        ! In/Out:
        !    r: On output the site specified by r (in units of the lattice
        !       sites) is mapped into the equivalent site inside the simulation
        !       cell.

        use basis, only: basis_fns, nbasis

        integer, intent(in) :: ndim, lvecs(ndim, 3**ndim)
        integer, intent(inout) :: r(ndim) 
        integer :: v(ndim)
        integer :: i, j

        do i = 1, 3**ndim
            ! Add all combinations of lattice vectors (stored in lvecs).
            v = r + lvecs(:,i)
            do j = 1, nbasis
                ! Loop over all basis functions and check if the shifted vector is
                ! now the same as any of these vectors. If so, it is in the cell,
                ! so keep it and return.
                if (all(v == basis_fns(j)%l)) then
                    r = v
                    return
                end if
            end do
        end do

    end subroutine map_vec_to_cell

end module real_lattice
