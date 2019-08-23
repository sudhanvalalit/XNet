!***************************************************************************************************
! xnet_nnu.f90 for XNet version 7 3/13/12
! This file contains reaction data structures for neutrino-induced reactions according to Froehlich
! PhD thesis 2007 (using rates from Zinner & Langanke) and routines to read the data and calculate
! the reaction rates.  It also contains the data structures for time history of the neutrino fluxes
! and temperatures.
!
! Credit: Carla Froehlich
!***************************************************************************************************

Module xnet_nnu
  !-------------------------------------------------------------------------------------------------
  ! This module contains the data and routines to calculate neutrino-induced reactions.
  !-------------------------------------------------------------------------------------------------
  Use xnet_conditions, Only: nhmx
  Use xnet_types, Only: dp
  Implicit None

  Integer, Parameter :: nnuspec = 4            ! Number of neutrino species in thermo history
  Integer, Parameter :: ntnu = 7               ! Number of neutrino temperature grid points per rate
  Real(dp), Parameter :: tnugrid(ntnu) = &     ! Neutrino temperature grid for NNU rate data
    & (/ 2.8, 3.5, 4.0, 5.0, 6.4, 8.0, 10.0 /)
  Real(dp), Parameter :: ltnugrid(ntnu) = log(tnugrid(:))

  Real(dp), Parameter :: sigmamin = 1.0e-100   ! Floor for neutrino cross-section rate

  Real(dp), Allocatable :: tmevnu(:,:,:)  ! Neutrino temperature [MeV]
  Real(dp), Allocatable :: fluxcms(:,:,:) ! Neutrino fluxes [cm^-2 s^-1]
  !$omp threadprivate(tmevnu,fluxcms)

  Real(dp), Dimension(:,:), Allocatable :: sigmanu ! dim(nnnu,ntnu)

Contains

  Subroutine read_nnu_data(nnnu,data_dir)
    !-----------------------------------------------------------------------------------------------
    ! This routine reads the neutrino cross sections [in units of 10^-42 cm^2]
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input variables
    Integer, Intent(in) :: nnnu
    Character(*), Intent(in) :: data_dir

    ! Local variables
    Integer :: i, j, lun_nnu

    Allocate (sigmanu(nnnu,ntnu))
    Open(newunit=lun_nnu, file=trim(data_dir)//"/netneutr", status='old')
    Do i = 1, nnnu
      Read(lun_nnu,*)
      Read(lun_nnu,*) (sigmanu(i,j), j=1,ntnu)
    EndDo
    Close(lun_nnu)
    sigmanu(:,:) = max( sigmamin, sigmanu(:,:) )

    Return
  End Subroutine read_nnu_data

  Subroutine nnu_rate(nnnu,time,rate,mask_in)
    !-----------------------------------------------------------------------------------------------
    ! This routine calculates the neutrino nucleus reaction rates [in s^-1] as 
    ! flux [cm^-2 s^-1] * cross section [cm^2].
    ! This flux already includes a factor 10^-42 from the cross sections.
    !
    ! Depending on the output of the prior simulation, the "neutrino flux" may need to be computed
    ! from neutrino luminosities.
    !-----------------------------------------------------------------------------------------------
    Use xnet_conditions, Only: nh, th
    Use xnet_controls, Only: nzbatchmx, lzactive, ineutrino
    Use xnet_types, Only: dp
    Use xnet_util, Only: safe_exp
    Implicit None

    ! Input variables
    Integer, Intent(in) :: nnnu
    Real(dp), Intent(in) :: time(nzbatchmx)

    ! Output variables
    Real(dp), Intent(out), Dimension(nnnu,nnuspec,nzbatchmx) :: rate

    ! Optional variables
    Logical, Optional, Target, Intent(in) :: mask_in(:)

    ! Local variables
    Real(dp) :: ltnu(nnuspec), flux(nnuspec)
    Real(dp) :: lsigmanu1(nnnu), lsigmanu2(nnnu)
    Real(dp) :: rcsnu(nnnu,nnuspec)
    Real(dp) :: rdt, rdltnu, ltnu1, ltnu2
    Integer :: izb, it, i, j, n
    Logical, Pointer :: mask(:)

    If ( present(mask_in) ) Then
      mask => mask_in(:)
    Else
      mask => lzactive(:)
    EndIf
    If ( .not. any(mask(:)) ) Return

    ! Only interpolate if neutrino reactions are on
    If ( ineutrino == 0 ) Then
      Do izb = 1, nzbatchmx
        If ( mask(izb) ) Then
          rate(:,:,izb) = 0.0
        EndIf
      EndDo
    Else
      Do izb = 1, nzbatchmx
        If ( mask(izb) ) Then

          ! For constant conditions (nh = 1), do not interpolate in time
          If ( nh(izb) == 1 ) Then
            n = 1

          ! Otherwise, intepolate the neutrino fluxes and temperature from time history
          Else
            Do i = 1, nh(izb)
              If ( time(izb) <= th(i,izb) ) Exit
            EndDo
            n = i
          EndIf

          ! Linear interpolation in log-space
          If ( n == 1 ) Then
            ltnu(:) = log(tmevnu(1,:,izb))
            flux(:) = fluxcms(1,:,izb)
          ElseIf ( n > nh(izb) ) Then
            ltnu(:) = log(tmevnu(nh(izb),:,izb))
            flux(:) = fluxcms(nh(izb),:,izb)
          Else
            rdt = (time(izb)-th(n-1,izb)) / (th(n,izb)-th(n-1,izb))
            ltnu(:) = rdt*log(tmevnu(n,:,izb)) + (1.0-rdt)*log(tmevnu(n-1,:,izb))
            flux(:) = safe_exp( rdt*log(fluxcms(n,:,izb)) + (1.0-rdt)*log(fluxcms(n-1,:,izb)) )
          EndIf

          ! Compute neutrino cross sections
          Do j = 1, nnuspec
            Do i = 1, ntnu
              If ( ltnu(j) <= ltnugrid(i) ) Exit
            EndDo
            it = i

            ! Log interpolation
            If ( it == 1 ) Then
              rcsnu(:,j) = sigmanu(:,1)
            ElseIf ( it > ntnu ) Then
              rcsnu(:,j) = sigmanu(:,ntnu)
            Else
              ltnu1 = ltnugrid(it-1)
              ltnu2 = ltnugrid(it)
              lsigmanu1(:) = log(sigmanu(:,it-1))
              lsigmanu2(:) = log(sigmanu(:,it))
              rdltnu = (ltnu(j)-ltnu1) / (ltnu2-ltnu1)
              rcsnu(:,j) = safe_exp( rdltnu*lsigmanu2 + (1.0-rdltnu)*lsigmanu1 )
            EndIf
            rate(:,j,izb) = flux(j)*rcsnu(:,j)
          EndDo
        EndIf
      EndDo
    EndIf

    Return
  End Subroutine nnu_rate

End Module xnet_nnu