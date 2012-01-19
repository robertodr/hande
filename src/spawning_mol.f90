module spawning_mol_system

! Module for spawning routine(s) related to the molecular system (ie one read in
! from an FCIDUMP file).

use const, only: i0, p

implicit none

contains

!--- Top level spawning routines ---

    subroutine spawn_mol(cdet, parent_sign, nspawn, connection)

        ! Attempt to spawn a new particle on a connected determinant for the
        ! molecular systems.
        !
        ! In:
        !    cdet: info on the current determinant (cdet) that we will spawn
        !        from.
        !    parent_sign: sign of the population on the parent determinant (i.e.
        !        either a positive or negative integer).
        ! Out:
        !    nspawn: number of particles spawned.  0 indicates the spawning
        !        attempt was unsuccessful.
        !    connection: excitation connection between the current determinant
        !        and the child determinant, on which progeny are spawned.

        use determinants, only: det_info
        use excitations, only: excit
        use spawning, only: attempt_to_spawn

        type(det_info), intent(in) :: cdet
        integer, intent(in) :: parent_sign
        integer, intent(out) :: nspawn
        type(excit), intent(out) :: connection

        real(p) :: pgen, hmatel

        ! 1. Generate random excitation.
        call gen_excit_mol(cdet, pgen, connection, hmatel)

        ! 2. Attempt spawning.
        nspawn = attempt_to_spawn(hmatel, pgen, parent_sign)

    end subroutine spawn_mol

    subroutine spawn_mol_no_renorm(cdet, parent_sign, nspawn, connection)

        ! Attempt to spawn a new particle on a connected determinant for the
        ! molecular systems.
        !
        ! This doesn't use excitation generators which exclude the case where,
        ! having selected (e.g.) 2 occupied orbitals (i and j) and the first virtual
        ! orbital (a), the final orbital is already occupied and so that
        ! excitation is impossible.  Whilst it is somewhat wasteful (generating
        ! excitations which can't be performed), there is a balance between the
        ! cost of generating forbidden excitations and the O(N) cost of
        ! renormalising the generation probabilities.
        !
        ! In:
        !    cdet: info on the current determinant (cdet) that we will spawn
        !        from.
        !    parent_sign: sign of the population on the parent determinant (i.e.
        !        either a positive or negative integer).
        ! Out:
        !    nspawn: number of particles spawned.  0 indicates the spawning
        !        attempt was unsuccessful.
        !    connection: excitation connection between the current determinant
        !        and the child determinant, on which progeny are spawned.

        use determinants, only: det_info
        use excitations, only: excit
        use spawning, only: attempt_to_spawn

        type(det_info), intent(in) :: cdet
        integer, intent(in) :: parent_sign
        integer, intent(out) :: nspawn
        type(excit), intent(out) :: connection

        real(p) :: pgen, hmatel

        ! 1. Generate random excitation.
        call gen_excit_mol_no_renorm(cdet, pgen, connection, hmatel)

        ! 2. Attempt spawning.
        nspawn = attempt_to_spawn(hmatel, pgen, parent_sign)

    end subroutine spawn_mol_no_renorm

!--- Excitation generation ---

    subroutine gen_excit_mol(cdet, pgen, connection, hmatel)

        ! Create a random excitation from cdet and calculate both the probability
        ! of selecting that excitation and the Hamiltonian matrix element.

        ! In:
        !    cdet: info on the current determinant (cdet) that we will gen
        !        from.
        !    parent_sign: sign of the population on the parent determinant (i.e.
        !        either a positive or negative integer).
        ! Out:
        !    pgen: probability of generating the excited determinant from cdet.
        !    connection: excitation connection between the current determinant
        !        and the child determinant, on which progeny are gened.
        !    hmatel: < D | H | D' >, the Hamiltonian matrix element between a
        !    determinant and a connected determinant in molecular systems.

        use determinants, only: det_info
        use excitations, only: excit
        use fciqmc_data, only: pattempt_single
        use excitations, only: find_excitation_permutation1, find_excitation_permutation2
        use hamiltonian_molecular, only: slater_condon1_mol_excit, slater_condon2_mol_excit

        use dSFMT_interface, only: genrand_real2

        type(det_info), intent(in) :: cdet
        real(p), intent(out) :: pgen, hmatel
        type(excit), intent(out) :: connection
        logical :: allowed_excitation

        integer :: ij_sym, ij_spin

        ! 1. Select single or double.

        if (genrand_real2() < pattempt_single) then

            ! 2a. Select orbital to excite from and orbital to excit into.
            call choose_ia_mol(cdet%f, cdet%occ_list, cdet%symunocc, connection%from_orb(1), &
                               connection%to_orb(1), allowed_excitation)
            connection%nexcit = 1

            if (allowed_excitation) then
                ! 3a. Probability of generating this excitation.
                pgen = calc_pgen_single_mol(cdet%occ_list, cdet%symunocc, connection%to_orb(1))

                ! 4a. Parity of permutation required to line up determinants.
                call find_excitation_permutation1(cdet%f, connection)

                ! 5a. Find the connecting matrix element.
                hmatel = slater_condon1_mol_excit(cdet%occ_list, connection%from_orb(1), connection%to_orb(1), connection%perm)
            else
                ! We have a highly restrained system and this det has no single
                ! excitations at all.  To avoid reweighting pattempt_single and
                ! pattempt_double (an O(N^3) operation), we simply return a null
                ! excitation
                hmatel = 0.0_p
                pgen = 1.0_p
            end if

        else

            ! 2b. Select orbitals to excite from and orbitals to excite into.
            call choose_ij_mol(cdet%occ_list, connection%from_orb(1), connection%from_orb(2), ij_sym, ij_spin)
            call choose_ab_mol(cdet%f, ij_sym, ij_spin, cdet%symunocc, connection%to_orb(1), &
                               connection%to_orb(2), allowed_excitation)
            connection%nexcit = 2

            if (allowed_excitation) then

                ! 3b. Probability of generating this excitation.
                pgen = calc_pgen_double_mol(ij_sym, connection%to_orb(1), connection%to_orb(2), &
                                            ij_spin, cdet%symunocc)

                ! 4b. Parity of permutation required to line up determinants.
                ! NOTE: connection%from_orb and connection%to_orb *must* be ordered.
                call find_excitation_permutation2(cdet%f, connection)

                ! 5b. Find the connecting matrix element.
                hmatel = slater_condon2_mol_excit(connection%from_orb(1), connection%from_orb(2), &
                                                  connection%to_orb(1), connection%to_orb(2), connection%perm)
            else
                ! Carelessly selected ij with no possible excitations.  Such
                ! events are not worth the cost of renormalising the generation
                ! probabilities.
                ! Return a null excitation.
                hmatel = 0.0_p
                pgen = 1.0_p
            end if

        end if

    end subroutine gen_excit_mol

    subroutine gen_excit_mol_no_renorm(cdet, pgen, connection, hmatel)

        ! Create a random excitation from cdet and calculate both the probability
        ! of selecting that excitation and the Hamiltonian matrix element.

        ! In:
        !    cdet: info on the current determinant (cdet) that we will gen
        !        from.
        !    parent_sign: sign of the population on the parent determinant (i.e.
        !        either a positive or negative integer).
        ! Out:
        !    pgen: probability of generating the excited determinant from cdet.
        !    connection: excitation connection between the current determinant
        !        and the child determinant, on which progeny are gened.
        !    hmatel: < D | H | D' >, the Hamiltonian matrix element between a
        !    determinant and a connected determinant in molecular systems.

        use basis, only: basis_fns
        use determinants, only: det_info
        use excitations, only: excit
        use fciqmc_data, only: pattempt_single
        use excitations, only: find_excitation_permutation1, find_excitation_permutation2
        use hamiltonian_molecular, only: slater_condon1_mol_excit, slater_condon2_mol_excit

        use dSFMT_interface, only: genrand_real2

        type(det_info), intent(in) :: cdet
        real(p), intent(out) :: pgen, hmatel
        type(excit), intent(out) :: connection

        logical :: allowed_excitation
        integer :: ij_sym, ij_spin

        ! 1. Select single or double.

        if (genrand_real2() < pattempt_single) then

            ! 2a. Select orbital to excite from and orbital to excit into.
            call find_ia_mol(cdet%f, cdet%occ_list, connection%from_orb(1), connection%to_orb(1), allowed_excitation)
            connection%nexcit = 1

            if (allowed_excitation) then
                ! 3a. Probability of generating this excitation.
                pgen = calc_pgen_single_mol_no_renorm(connection%to_orb(1))

                ! 4a. Parity of permutation required to line up determinants.
                call find_excitation_permutation1(cdet%f, connection)

                ! 5a. Find the connecting matrix element.
                hmatel = slater_condon1_mol_excit(cdet%occ_list, connection%from_orb(1), connection%to_orb(1), connection%perm)
            else
                ! Forbidden---connection%to_orb(1) is already occupied.
                hmatel = 0.0_p
                pgen = 1.0_p ! Avoid any dangerous division by pgen by returning a sane (but cheap) value.
            end if

        else

            ! 2b. Select orbitals to excite from and orbitals to excite into.
            call choose_ij_mol(cdet%occ_list, connection%from_orb(1), connection%from_orb(2), ij_sym, ij_spin)
            call find_ab_mol(cdet%f, ij_sym, ij_spin, connection%to_orb(1), connection%to_orb(2), allowed_excitation)
            connection%nexcit = 2

            if (allowed_excitation) then
                ! 3b. Probability of generating this excitation.
                pgen = calc_pgen_double_mol_no_renorm(connection%to_orb(1), connection%to_orb(2), ij_spin)

                ! 4b. Parity of permutation required to line up determinants.
                ! NOTE: connection%from_orb and connection%to_orb *must* be ordered.
                call find_excitation_permutation2(cdet%f, connection)

                ! 5b. Find the connecting matrix element.
                hmatel = slater_condon2_mol_excit(connection%from_orb(1), connection%from_orb(2), &
                                                  connection%to_orb(1), connection%to_orb(2), connection%perm)
            else
                ! Forbidden---connection%to_orb(2) is already occupied.
                hmatel = 0.0_p
                pgen = 1.0_p ! Avoid any dangerous division by pgen by returning a sane (but cheap) value.
            end if

        end if

    end subroutine gen_excit_mol_no_renorm

!--- Select random orbitals involved in a valid single excitation ---

    subroutine choose_ia_mol(f, occ_list, symunocc, i, a, allowed_excitation)

        ! Randomly choose a single excitation, i->a, of a determinant for
        ! molecular systems.

        ! In:
        !    f: bit string representation of the Slater determinant from which
        !        an electron is excited.
        !    occ_list: integer list of occupied spin-orbitals in the determinant.
        !    symunocc: number of unoccupied orbitals of each spin and
        !        irreducible representation.  The same indexing scheme as
        !        nbasis_sym_spin (in the point_group_symmetry module) is used.
        ! Out:
        !    i: orbital in determinant from which an electron is excited.
        !    a: previously unoccupied orbital into which an electron is excited.
        !        Not set if allowed_excitation is false.
        !    allowed_excitation: false if there are no possible single
        !        excitations from the determinant which conserve spin and spatial
        !        symmetry.

        use basis, only: basis_length, basis_fns, bit_lookup
        use point_group_symmetry, only: nbasis_sym_spin, sym_spin_basis_fns
        use system, only: nel, sym0

        use dSFMT_interface, only: genrand_real2

        integer(i0), intent(in) :: f(basis_length)
        integer, intent(in) :: occ_list(nel), symunocc(:,sym0:)
        integer, intent(out) :: i, a
        logical, intent(out) :: allowed_excitation

        integer :: ims, isym, ind

        ! Does this determinant have any possible single excitations?
        allowed_excitation = .false.
        do i = 1, nel
            ims = (basis_fns(occ_list(i))%Ms+3)/2
            isym = basis_fns(occ_list(i))%sym
            if (symunocc(ims, isym) /= 0) then
                allowed_excitation = .true.
                exit
            end if
        end do

        if (allowed_excitation) then
            ! We could wrap around find_ia_mol, but it's more efficient to have
            ! a custom generator instead.  The cost of an extra few lines is worth
            ! the speed...

            do
                ! Select an occupied orbital at random.
                i = occ_list(int(genrand_real2()*nel)+1)
                ! Conserve symmetry (spatial and spin) in selecting a.
                ims = (basis_fns(i)%Ms+3)/2
                isym = basis_fns(i)%sym
                if (symunocc(ims, isym) /= 0) then
                    ! Found i.  Now find a...
                        ! It's cheaper to draw additional random numbers than
                        ! decode the full list of unoccupied orbitals,
                        ! especially as the number of basis functions is usually
                        ! much larger than the number of electrons.
                        do
                            ind = int(nbasis_sym_spin(ims,isym)*genrand_real2())+1
                            a = sym_spin_basis_fns(ind,ims,isym)
                            if (.not.btest(f(bit_lookup(2,a)), bit_lookup(1,a))) exit
                        end do
                    exit
                end if
            end do

        end if

    end subroutine choose_ia_mol

!--- Select random orbitals involved in a valid double excitation ---

    subroutine choose_ij_mol(occ_list, i, j, ij_sym, ij_spin)

        ! Randomly select two occupied orbitals in a determinant from which
        ! electrons are excited as part of a double excitation.
        !
        ! In:
        !    occ_list: integer list of occupied spin-orbitals in the determinant.
        ! Out:
        !    i, j: orbitals in determinant from which two electrons are excited.
        !        Note that i,j are ordered such that i<j.
        !    ij_sym: irreducible representation spanned by the codensity
        !        \phi_i*\phi_j.
        !    ij_spin: spin label of the combined ij codensity.
        !        ij_spin = -2   i,j both down
        !                =  0   i up and j down or vice versa
        !                =  2   i,j both up

        use basis, only: basis_fns
        use system, only: nel
        use point_group_symmetry, only: cross_product_pg_basis

        use dSFMT_interface, only: genrand_real2

        integer, intent(in) :: occ_list(nel)
        integer, intent(out) :: i, j, ij_sym, ij_spin

        integer :: ind

        ! See comments in choose_ij_k for how the occupied orbitals are indexed
        ! to allow one random number to decide the ij pair.

        ind = int(genrand_real2()*nel*(nel-1)/2) + 1

        ! i,j initially refer to the indices in the lists of occupied spin-orbitals
        ! rather than the spin-orbitals.
        ! Note that the indexing scheme for the strictly lower triangular array
        ! assumes j>i.  As occ_list is ordered, this means that we will return
        ! i,j (referring to spin-orbitals) where j>i.  This ordering is
        ! convenient subsequently, e.g. is assumed in the
        ! find_excitation_permutation2 routine.
        j = int(1.50_p + sqrt(2*ind-1.750_p))
        i = ind - ((j-1)*(j-2))/2

        i = occ_list(i)
        j = occ_list(j)

        ij_sym = cross_product_pg_basis(i,j)
        ! ij_spin = -2 (down, down), 0 (up, down or down, up), +2 (up, up)
        ij_spin = basis_fns(i)%Ms + basis_fns(j)%Ms

    end subroutine choose_ij_mol

    subroutine choose_ab_mol(f, sym, spin, symunocc, a, b, allowed_excitation)

        ! Select a random pair of orbitals to excite into as part of a double
        ! excitation, given that the (i,j) pair of orbitals to excite from have
        ! already been selected.
        !
        ! In:
        !    f: bit string representation of the Slater determinant from which
        !        an electron is excited.
        !    sym: irreducible representation spanned by the (i,j) codensity.
        !    spin: spin label of the selected (i,j) pair.  Set to -2 if both ia
        !        and j are down, +2 if both are up and 0 otherwise.
        !    symunocc: number of unoccupied orbitals of each spin and
        !        irreducible representation.  The same indexing scheme as
        !        nbasis_sym_spin (in the point_group_symmetry module) is used.
        ! Out:
        !    a, b: unoccupied orbitals into which electrons are excited.
        !        Note that a,b are ordered such that a<b.
        !        Not set if allowed_excitation is false.
        !    allowed_excitation: false if there are no possible (a,b) pairs
        !        which conserve spin and spatial symmetry given the choice of
        !        (i,j).

        use basis, only: basis_length, basis_fns, bit_lookup, nbasis
        use system, only: nel, sym0, nsym
        use point_group_symmetry, only: cross_product_pg_sym, nbasis_sym_spin, sym_spin_basis_fns

        use dSFMT_interface, only: genrand_real2

        integer(i0), intent(in) :: f(basis_length)
        integer, intent(in) :: sym, spin, symunocc(:,sym0:)
        integer, intent(out) :: a, b
        logical, intent(out) :: allowed_excitation

        integer :: isyma, isymb, imsa, imsb, ims_min, ims_max, fac, shift, na, ind

        ! Is there a possible (a,b) pair which conserves symmetry once the (i,j)
        ! pair has been selected?
        ! We don't renormalise the probability generators for such instances, so
        ! need to return a null excitation.
        allowed_excitation = .false.
        select case(spin)
        case(-2)
            do isyma = sym0, nsym+(sym0-1)
                isymb = cross_product_pg_sym(isyma, sym)
                if ( symunocc(1,isyma) > 0 .and. &
                        ( symunocc(1,isymb) > 1 .or. &
                        ( symunocc(1,isymb) == 1 .and. (isyma /= isymb))) ) then
                    allowed_excitation = .true.
                    exit
                end if
            end do

            ! nbasis/2 functions of this spin.
            ! all basis functions of this spin are odd.
            ! Convert number, x, in range [1,nbasis/2] to odd number in range
            ! [1,nbasis] using 2*x-1
            fac = 2
            shift = 1
            na = nbasis/2
        case(0)
            do isyma = sym0, nsym+(sym0-1)
                isymb = cross_product_pg_sym(isyma, sym)
                if ( (symunocc(1,isyma) > 0 .and. symunocc(2,isymb) > 0) .or. &
                     (symunocc(2,isyma) > 0 .and. symunocc(1,isymb) > 0) ) then
                    allowed_excitation = .true.
                    exit
                end if
            end do

            ! Can select from any of the nbasis functions.
            ! Convert number, x, in range [1,nbasis] to any number in range
            ! [1,nbasis] using simply x (for compatibility with spin=-2,2).
            fac = 1
            shift = 0
            na = nbasis
        case(2)
            do isyma = sym0, nsym+(sym0-1)
                isymb = cross_product_pg_sym(isyma, sym)
                if ( symunocc(2,isyma) > 0 .and. &
                        ( symunocc(2,isymb) > 1 .or. &
                        ( symunocc(2,isymb) == 1 .and. (isyma /= isymb))) ) then
                    allowed_excitation = .true.
                    exit
                end if
            end do

            ! nbasis/2 functions of this spin.
            ! all basis functions of this spin are even.
            ! Convert number, x, in range [1,nbasis/2] to even number in range
            ! [1,nbasis] using 2*x
            fac = 2
            shift = 0
            na = nbasis/2
        end select

        if (allowed_excitation) then
            ! We could wrap around find_ab_mol, but it's more efficient to have
            ! a custom generator instead.  The cost of an extra few lines is worth
            ! the speed...

            do
                ! Find a.  See notes in find_ab_mol.
                a = int(genrand_real2()*na) + 1
                ! convert to down or up orbital
                a = fac*a-shift
                ! If a is unoccupied and there's a possbible b, then have found
                ! first orbital to excite into.
                if (.not.btest(f(bit_lookup(2,a)), bit_lookup(1,a))) then
                    ! b must conserve spatial and spin symmetry.
                    imsb = (spin-basis_fns(a)%Ms+3)/2
                    isymb = cross_product_pg_sym(sym, basis_fns(a)%sym)
                    ! Is there a possible b?
                    if ( (symunocc(imsb,isymb) > 1) .or. &
                            (symunocc(imsb,isymb) == 1 .and. (isymb /= basis_fns(a)%sym .or. spin == 0)) ) then
                        ! Possible b.  Find it.
                        do
                            ind = int(nbasis_sym_spin(imsb,isymb)*genrand_real2())+1
                            b = sym_spin_basis_fns(ind,imsb,isymb)
                            ! If b is unoccupied and is different from a then
                            ! we've found the excitation.
                            if ( b /= a .and. .not.btest(f(bit_lookup(2,b)),bit_lookup(1,b)) ) exit
                        end do
                        exit
                    end if
                end if
            end do

            ! It is useful to return a,b ordered (e.g. for the find_excitation_permutation2 routine).
            if (a > b) then
                ind = a
                a = b
                b = ind
            end if

        end if

    end subroutine choose_ab_mol

!--- Select random orbitals in single excitations ---

    subroutine find_ia_mol(f, occ_list, i, a, allowed_excitation)

        ! Randomly choose a single excitation, i->a, of a determinant for
        ! molecular systems.  This routine does not reject a randomly selected
        ! a if that orbital is already occupied, which makes the excitation
        ! generation and calculation of the generation probability simpler and
        ! faster.  The downside is that the sampling is substantially more
        ! inefficient for small/symmetry constrained systems.
        !
        ! In:
        !    f: bit string representation of the Slater determinant from which
        !        an electron is excited.
        !    occ_list: integer list of occupied spin-orbitals in the determinant.
        ! Out:
        !    i: orbital in determinant from which an electron is excited.
        !    a: previously unoccupied orbital into which an electron is excited.
        !        Not necessarily set if allowed_excitation is false.
        !    allowed_excitation: false if there are no possible single
        !        excitations from the determinant which conserve spin and spatial
        !        symmetry or if a is already occupied.

        use basis, only: basis_length, basis_fns, bit_lookup
        use point_group_symmetry, only: nbasis_sym_spin, sym_spin_basis_fns
        use system, only: nel

        use dSFMT_interface, only: genrand_real2

        integer(i0), intent(in) :: f(basis_length)
        integer, intent(in) :: occ_list(nel)
        integer, intent(out) :: i, a
        logical, intent(out) :: allowed_excitation

        integer :: ims, isym, ind

        ! Select an occupied orbital at random.
        i = occ_list(int(genrand_real2()*nel)+1)

        ! Conserve symmetry (spatial and spin) in selecting a.
        ims = (basis_fns(i)%Ms+3)/2
        isym = basis_fns(i)%sym
        ind = int(nbasis_sym_spin(ims,isym)*genrand_real2())+1
        if (nbasis_sym_spin(ims,isym) == 0) then
            ! No orbitals with the correct symmetry.
            allowed_excitation = .false.
        else
            a = sym_spin_basis_fns(ind,ims,isym)
            ! Is a already occupied in the determinant f?  If so, the excitation is
            ! not permitted.
            allowed_excitation = .not.btest(f(bit_lookup(2,a)), bit_lookup(1,a))
        end if

    end subroutine find_ia_mol

!--- Select random orbitals in double excitations ---

    subroutine find_ab_mol(f, sym, spin, a, b, allowed_excitation)

        ! Select a random pair of orbitals to excite into as part of a double
        ! excitation, given that the (i,j) pair of orbitals to excite from have
        ! already been selected.  The spin and irreducible representation
        ! spanned by the fourth orbital is completely determined by the choice
        ! of the first three orbitals in the double excitation.  This routine
        ! does not explicitly reject excitations where the fourth orbital chosen
        ! is already occupied, instead returning allowed_excitation as false.
        ! This makes the excitation generation and calculation of the generation
        ! probability simpler and faster at the cost of makin the sampling
        ! substantially more inefficient.  Nevertheless, this approach can be
        ! useful in large systems.
        !
        ! In:
        !    f: bit string representation of the Slater determinant from which
        !        an electron is excited.
        !    sym: irreducible representation spanned by the (i,j) codensity.
        !    spin: spin label of the selected (i,j) pair.  Set to -2 if both ia
        !        and j are down, +2 if both are up and 0 otherwise.
        ! Out:
        !    a, b: unoccupied orbitals into which electrons are excited.
        !        Note that a,b are ordered such that a<b.
        !        Not necessarily set if allowed_excitation is false.
        !    allowed_excitation: false if there are no possible (a,b) pairs
        !        which conserve spin and spatial symmetry given the choice of
        !        (i,j) or given the choice of (i,j,a).

        use basis, only: basis_length, basis_fns, bit_lookup, nbasis
        use point_group_symmetry, only: nbasis_sym_spin, sym_spin_basis_fns, cross_product_pg_sym
        use system, only: nel

        use dSFMT_interface, only: genrand_real2

        integer(i0), intent(in) :: f(basis_length)
        integer, intent(in) :: sym, spin
        integer, intent(out) :: a, b
        logical, intent(out) :: allowed_excitation

        integer :: ims, isym, ind, shift, na, fac

        ! Select a virtual orbital at random.
        ! Ensure spin can be conserved...
        select case(spin)
        case(-2)
            ! a must be down.
            ! Convert number, x, in range [1,nbasis/2] to odd number in range
            ! [1,nbasis] using 2*x-1
            fac = 2
            shift = 1
            na = nbasis/2
        case(0)
            ! a can be up or down.
            ! Convert number, x, in range [1,nbasis] to any number in range
            ! [1,nbasis] using simply x (for compatibility with spin=-2,2).
            fac = 1
            shift = 0
            na = nbasis
        case(2)
            ! a must be up.
            ! Convert number, x, in range [1,nbasis/2] to even number in range
            ! [1,nbasis] using 2*x
            fac = 2
            shift = 0
            na = nbasis/2
        end select

        do
            ! We assume that the user is not so crazy that he/she is
            ! running a calculation where there exists no virtual
            ! orbitals of a given spin.
            ! random integer between 1 and # possible a orbitals.
            a = int(genrand_real2()*na) + 1
            ! convert to down orbital (ie odd integer between 1 and
            ! nbasis-1) or up orbital (ie even integer between 2 and nbasis)
            ! or to any orbital.
            a = fac*a-shift
            ! If a is unoccupied, then have found first orbital to excite into.
            if (.not.btest(f(bit_lookup(2,a)), bit_lookup(1,a))) exit
        end do

        ! Conserve symmetry (spatial and spin) in selecting the fourth orbital.
        ! Ms_i + Ms_j = Ms_a + Ms_b (Ms_i = -1,+1)
        ! => Ms_b = Ms_i + Ms_j - Ms_a
        ims = (spin-basis_fns(a)%Ms+3)/2
        ! sym_i x sym_j x sym_a = sym_b
        ! (at least for Abelian point groups)
        isym = cross_product_pg_sym(sym, basis_fns(a)%sym)

        if (nbasis_sym_spin(ims,isym) == 0) then
            ! No orbitals with the correct symmetry.
            allowed_excitation = .false.
        else if (spin /= 0 .and. isym == basis_fns(a)%sym .and. nbasis_sym_spin(ims,isym) == 1) then
            allowed_excitation = .false.
        else
            do
                ind = int(nbasis_sym_spin(ims,isym)*genrand_real2())+1
                b = sym_spin_basis_fns(ind,ims,isym)
                if (b /= a) exit
            end do

            ! Is b already occupied in the determinant f?  If so, the excitation is
            ! not permitted.
            allowed_excitation = .not.btest(f(bit_lookup(2,b)), bit_lookup(1,b))

            ! It is useful to return a,b ordered (e.g. for the find_excitation_permutation2 routine).
            if (a > b) then
                ind = a
                a = b
                b = ind
            end if
        end if

    end subroutine find_ab_mol

!--- Excitation generation probabilities ---

    pure function calc_pgen_single_mol(occ_list, symunocc, a) result(pgen)

        ! In:
        !    occ_list: integer list of occupied spin-orbitals in the determinant.
        !    symunocc: number of unoccupied orbitals of each spin and
        !        irreducible representation.  The same indexing scheme as
        !        nbasis_sym_spin (in the point_group_symmetry module) is used.
        !    a: previously unoccupied orbital into which an electron is excited.
        ! Returns:
        !    The probability of generating the excitation i->a, where we select
        !    i uniformly from the list of occupied orbitals with allowed
        !    excitations (i.e. at least one single excitation exists involving
        !    those orbitals) and a is selected from the list of unoccupied
        !    orbitals which conserve spin and spatial symmetry.

        ! WARNING: We assume that the excitation is actually valid.
        ! This routine does *not* calculate the correct probability that
        ! a forbidden excitation (e.g. no possible single excitations exist) is
        ! generated.  The correct way to handle those excitations is to
        ! explicitly reject them.  The generation probabilites of allowed
        ! excitations correctly take into account such rejected events.

        use basis, only: basis_fns
        use fciqmc_data, only: pattempt_single
        use system, only: nel, sym0

        real(p) :: pgen
        integer, intent(in) :: occ_list(nel), symunocc(:,sym0:), a

        integer :: ims, isym, i, ni

        ! The generation probability, pgen, is:
        !   pgen = p_single p(i) p(a|i)
        !        = p_single 1/nel 1/symunocc(ms_i, sym_i)

        ni = nel
        do i = 1, nel
            ims = (basis_fns(occ_list(i))%Ms+3)/2
            isym = basis_fns(occ_list(i))%sym
            if (symunocc(ims,isym) == 0) ni = ni - 1
        end do

        ims = (basis_fns(a)%Ms+3)/2
        isym = basis_fns(a)%sym
        pgen = pattempt_single/(ni*symunocc(ims,isym))

    end function calc_pgen_single_mol

    pure function calc_pgen_double_mol(ij_sym, a, b, spin, symunocc) result(pgen)

        ! In:
        !    ij_sym: irreducible representation spanned by the (i,j) codensity.
        !        As symmetry is conserved in allowed excitations, this is also
        !        the irreducible representation spanned by the (a, b) codensity.
        !    a, b: unoccupied orbitals into which electrons are excited.
        !    spin: spin label of the selected (a,b) pair.  Set to -2 if both ia
        !        and j are down, +2 if both are up and 0 otherwise.  As spin is
        !        conserved, this is also the spin label of the selected (i,j)
        !        pair in the double excitation (i,j) -> (a,b).
        !    symunocc: number of unoccupied orbitals of each spin and
        !        irreducible representation.  The same indexing scheme as
        !        nbasis_sym_spin (in the point_group_symmetry module) is used.
        ! Returns:
        !    The probability, p(D_{ij}^{ab}|D), of selecting to excite to
        !    determinant D_{ij}^{ab} from determinant D, assuming that (i,j)
        !    have been selected from the occupied orbitals, a is selected from
        !    an unoccupied orbital and b is selected from the set of unoccupied
        !    orbitals which conserve spin and spatial symmetry.

        ! WARNING: We assume that the excitation is actually valid.
        ! This routine does *not* calculate the correct probability that
        ! a forbidden excitation (e.g. due to no possible a orbitals given the
        ! choice of (i,j)) is generated.  The correct way to handle those
        ! excitations is to explicitly reject them.  The generation probabilites
        ! of allowed excitations correctly take into account such rejected
        ! events.

        use basis, only: basis_fns
        use fciqmc_data, only: pattempt_double
        use system, only: nel, nvirt, nvirt_alpha, nvirt_beta, sym0, nsym
        use point_group_symmetry, only: nbasis_sym_spin, cross_product_pg_sym

        real(p) :: pgen
        integer, intent(in) :: ij_sym, a, b, spin, symunocc(:,sym0:)

        integer :: imsa, isyma, imsb, isymb, n_aij, ims_min, ims_max
        real(p) :: p_bija, p_aijb

        ! p(i,j) = 1/binom(nel,2) = 2/(nel*(nel-1))
        ! p(a|i,j) = | 1/(nbasis-nel) if i,j are (up,down) or (down,up)
        !            | 1/(nbasis/2-nalpha) if i,j are (up,up)
        !            | 1/(nbasis/2-nbeta) if i,j are (down,down)
        ! p(b|i,j,a) = 1/symunocc(ms_b, sym_b), where ms_b and sym_b are
        ! such that spin and spatial symmetry are conserved
        ! p(b|i,j) = p(a|i,j) by symmetry.
        ! p(a|i,j,b) = 1/symunocc(ms_a, sym_a), where ms_a and sym_a are
        ! such that spin and spatial symmetry are conserved.
        ! n.b. p(a|i,j,b) =/= p(b|i,j,a) in general.

        imsa = (basis_fns(a)%ms+3)/2
        imsb = (basis_fns(b)%ms+3)/2

        ! Count number of possible choices of a, given the choice of (i,j).
        ! Find number of possible b, given the choice of (i,j,a).
        ! It is more efficient to deal with the different spin cases separately
        ! and explicitly.
        select case(spin)
        case(-2)
            ! # a.
            n_aij = nvirt_beta
            do isyma = sym0, nsym+(sym0-1)
                ! find corresponding isymb.
                isymb = cross_product_pg_sym(isyma, ij_sym)
                if (symunocc(1, isymb) == 0) then
                    n_aij = n_aij - symunocc(1,isyma)
                else if (isyma == isymb .and. symunocc(1, isymb) == 1) then
                    ! if up,up / down,down
                    n_aij = n_aij - symunocc(1,isyma)
                end if
            end do
            ! # b.
            if (basis_fns(a)%sym == basis_fns(b)%sym) then
                p_aijb = 1.0_p/(symunocc(imsa,basis_fns(a)%sym)-1)
                p_bija = 1.0_p/(symunocc(imsb,basis_fns(b)%sym)-1)
            else
                p_aijb = 1.0_p/symunocc(imsa,basis_fns(a)%sym)
                p_bija = 1.0_p/symunocc(imsb,basis_fns(b)%sym)
            end if
        case(0)
            ! # a.
            n_aij = nvirt
            do isyma = sym0, nsym+(sym0-1)
                ! find corresponding isymb.
                isymb = cross_product_pg_sym(isyma, ij_sym)
                if (symunocc(1, isymb) == 0) then
                    n_aij = n_aij - symunocc(2,isyma)
                end if
                if (symunocc(2, isymb) == 0) then
                    n_aij = n_aij - symunocc(1,isyma)
                end if
            end do
            ! # b.  b cannot have same spin and symmetry as a.
            p_aijb = 1.0_p/symunocc(imsa,basis_fns(a)%sym)
            p_bija = 1.0_p/symunocc(imsb,basis_fns(b)%sym)
        case(2)
            ! # a.
            n_aij = nvirt_alpha
            do isyma = sym0, nsym+(sym0-1)
                ! find corresponding isymb.
                isymb = cross_product_pg_sym(isyma, ij_sym)
                if (symunocc(2, isymb) == 0) then
                    n_aij = n_aij - symunocc(2,isyma)
                else if (isyma == isymb .and. symunocc(2, isymb) == 1) then
                    ! if up,up / down,down
                    n_aij = n_aij - symunocc(2,isyma)
                end if
            end do
            ! # b.
            if (basis_fns(a)%sym == basis_fns(b)%sym) then
                p_aijb = 1.0_p/(symunocc(imsa,basis_fns(a)%sym)-1)
                p_bija = 1.0_p/(symunocc(imsb,basis_fns(b)%sym)-1)
            else
                p_aijb = 1.0_p/symunocc(imsa,basis_fns(a)%sym)
                p_bija = 1.0_p/symunocc(imsb,basis_fns(b)%sym)
            end if
        end select

        pgen = 2*pattempt_double/(nel*(nel-1)*n_aij)*(p_bija+p_aijb)

    end function calc_pgen_double_mol

    pure function calc_pgen_single_mol_no_renorm(a) result(pgen)

        ! In:
        !    a: previously unoccupied orbital into which an electron is excited.
        ! Returns:
        !    The probability of generating the excitation i->a, where we select
        !    i uniformly from the list of occupied orbitals and a is selected
        !    from the list of orbitals (both occupied and unoccupied) which
        !    conserve spin and spatial symmetry.  Note that the probability is
        !    actually independent of i due to the uniform selection of i.

        ! WARNING: We assume that the excitation is actually valid.
        ! This routine does *not* calculate the correct probability that
        ! a forbidden excitation (e.g. due to a actually being occupied) is
        ! generated.  The correct way to handle those excitations is to
        ! explicitly reject them.  The generation probabilites of allowed
        ! excitations correctly take into account such rejected events.

        use basis, only: basis_fns
        use fciqmc_data, only: pattempt_single
        use system, only: nel
        use point_group_symmetry, only: nbasis_sym_spin

        real(p) :: pgen
        integer, intent(in) :: a

        integer :: ims, isym

        ! We explicitly reject excitations i->a where a is already
        ! occupied, so the generation probability, pgen, is simple:
        !   pgen = p_single p(i) p(a|i)
        !        = p_single 1/nel 1/nbasis_sym_spin(ms_i, sym_i)

        ims = (basis_fns(a)%Ms+3)/2
        isym = basis_fns(a)%sym
        pgen = pattempt_single/(nel*nbasis_sym_spin(ims,isym))

    end function calc_pgen_single_mol_no_renorm

    pure function calc_pgen_double_mol_no_renorm(a, b, spin) result(pgen)

        ! In:
        !    a, b: unoccupied orbitals into which electrons are excited.
        !    spin: spin label of the selected (a,b) pair.  Set to -2 if both ia
        !        and j are down, +2 if both are up and 0 otherwise.  As spin is
        !        conserved, this is also the spin label of the selected (i,j)
        !        pair in the double excitation (i,j) -> (a,b).
        ! Returns:
        !    The probability, p(D_{ij}^{ab}|D), of selecting to excite to
        !    determinant D_{ij}^{ab} from determinant D, assuming that (i,j)
        !    have been selected from the occupied orbitals, a is selected from
        !    an unoccupied orbital and b is selected from the set of orbitals
        !    which conserve spin and spatial symmetry.  (Note: in this scheme,
        !    b is not necessarily unoccupied.)

        ! WARNING: We assume that the excitation is actually valid.
        ! This routine does *not* calculate the correct probability that
        ! a forbidden excitation (e.g. due to a or b actually being occupied) is
        ! generated.  The correct way to handle those excitations is to
        ! explicitly reject them.  The generation probabilites of allowed
        ! excitations correctly take into account rejected events where a/b is
        ! occupied.  This problem arises because if a or b are actually occpied,
        ! then p(a|ijb) or p(b|ijb) = 0.  We do not handle such cases here.

        use basis, only: basis_fns
        use fciqmc_data, only: pattempt_double
        use system, only: nel, nvirt, nvirt_alpha, nvirt_beta
        use point_group_symmetry, only: nbasis_sym_spin

        real(p) :: pgen
        integer, intent(in) :: a, b, spin

        integer :: imsa, isyma, imsb, isymb, n_aij
        real(p) :: p_bija, p_aijb

        ! We explicitly reject excitations i,j->a,b where b is already
        ! occupied, so the generation probability, pgen, is simple:
        ! pgen = p_double p(i,j) [ p(a|i,j) p(b|i,j,a) + p(b|i,j) p(a|i,j,b) ]
        !
        ! p(i,j) = 1/binom(nel,2) = 2/(nel*(nel-1))
        ! p(a|i,j) = | 1/(nbasis-nel) if i,j are (up,down) or (down,up)
        !            | 1/(nbasis/2-nalpha) if i,j are (up,up)
        !            | 1/(nbasis/2-nbeta) if i,j are (down,down)
        ! p(b|i,j,a) = 1/nbasis_sym_spin(ms_b, sym_b), where ms_b and sym_b are
        ! such that spin and spatial symmetry are conserved
        ! p(b|i,j) = p(a|i,j) by symmetry.
        ! p(a|i,j,b) = 1/nbasis_sym_spin(ms_a, sym_a), where ms_a and sym_a are
        ! such that spin and spatial symmetry are conserved.
        ! n.b. p(a|i,j,b) =/= p(b|i,j,a) in general.

        select case(spin)
        case(-2)
            n_aij = nvirt_beta
        case(0)
            n_aij = nvirt
        case(2)
            n_aij = nvirt_alpha
        end select

        imsa = (basis_fns(a)%ms+3)/2
        isyma = basis_fns(a)%sym
        imsb = (basis_fns(b)%ms+3)/2
        isymb = basis_fns(b)%sym

        if (isyma == isymb .and. imsa == imsb) then
            ! b cannot be the same as a.
            p_aijb = 1.0_p/(nbasis_sym_spin(imsa, isyma)-1)
            p_bija = 1.0_p/(nbasis_sym_spin(imsb, isymb)-1)
        else
            p_aijb = 1.0_p/nbasis_sym_spin(imsa, isyma)
            p_bija = 1.0_p/nbasis_sym_spin(imsb, isymb)
        end if

        pgen = 2*pattempt_double/(nel*(nel-1)*n_aij)*(p_bija+p_aijb)

    end function calc_pgen_double_mol_no_renorm

end module spawning_mol_system
